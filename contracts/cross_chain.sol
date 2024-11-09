
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SecureCrossChainBridge is Ownable {
    // Pause state
    bool public paused;

    // Core structures
    struct BridgeConfig {
        uint256 chainId;
        uint256 requiredConfirmations;
        uint256 validatorThreshold;
        uint256 pauseTimeout;
    }

    struct TokenConfig {
        address localToken;
        bool isNative;
        uint256 minimumAmount;
        uint256 maximumAmount;
        uint256 dailyLimit;
        mapping(uint256 => address) remoteTokens;
    }

    struct TransferRequest {
        address token;
        address sender;
        address recipient;
        uint256 amount;
        uint256 targetChain;
        uint256 timestamp;
        uint256 deadline;
        bool executed;
    }

    // Constants
    uint256 public constant DELAY_PERIOD = 24 hours;
    uint256 public constant MAX_VALIDATORS = 50;
    uint256 public constant MIN_VALIDATORS = 3;

    // Bridge configuration
    BridgeConfig public bridgeConfig;
    mapping(uint256 => bool) public supportedChains;
    mapping(address => TokenConfig) public tokenConfigs;
    
    // Validator management
    mapping(address => bool) public validators;
    uint256 public validatorCount;
    uint256 public requiredSignatures;
    
    // Transfer tracking
    mapping(bytes32 => TransferRequest) public transferRequests;
    mapping(bytes32 => mapping(address => bool)) public validatorApprovals;
    mapping(bytes32 => uint256) public approvalCounts;
    
    // Rate limiting
    mapping(address => uint256) public dailyLimits;
    mapping(address => uint256) public dailyUsage;
    mapping(address => uint256) public lastResetTime;

    // Events
    event Paused(address account);
    event Unpaused(address account);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ChainAdded(uint256 indexed chainId);
    event ChainRemoved(uint256 indexed chainId);
    event TokenConfigured(address indexed token, uint256 indexed chainId);
    event TransferInitiated(
        bytes32 indexed transferId,
        address indexed token,
        address sender,
        address recipient,
        uint256 amount,
        uint256 targetChain
    );
    event TransferApproved(bytes32 indexed transferId, address indexed validator);
    event TransferExecuted(
        bytes32 indexed transferId,
        address indexed token,
        address recipient,
        uint256 amount
    );
    event EmergencyWithdrawal(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    // Custom errors
    error BridgePaused();
    error BridgeNotPaused();
    error InvalidAmount();
    error TokenNotSupported();
    error ChainNotSupported();
    error InvalidValidator();
    error TooManyValidators();
    error InsufficientValidators();
    error TransferNotFound();
    error TransferAlreadyExecuted();
    error SignatureAlreadySubmitted();
    error DelayNotElapsed();
    error DailyLimitExceeded();
    error QuorumNotReached();
    error InvalidSignature();
    error Unauthorized();

    // Modifiers
    modifier whenNotPaused() {
        if(paused) revert BridgePaused();
        _;
    }

    modifier whenPaused() {
        if(!paused) revert BridgeNotPaused();
        _;
    }

    modifier validChain(uint256 chainId) {
        if (!supportedChains[chainId]) revert ChainNotSupported();
        _;
    }

    modifier onlyValidator() {
        if (!validators[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(uint256 _chainId, uint256 _requiredSignatures) Ownable(msg.sender) {
        if (_requiredSignatures < MIN_VALIDATORS) revert InsufficientValidators();
        
        bridgeConfig = BridgeConfig({
            chainId: _chainId,
            requiredConfirmations: _requiredSignatures,
            validatorThreshold: _requiredSignatures,
            pauseTimeout: DELAY_PERIOD
        });

        requiredSignatures = _requiredSignatures;
        supportedChains[_chainId] = true;
        paused = false;
    }

    function pause() external onlyOwner {
        if(paused) revert BridgePaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if(!paused) revert BridgeNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function addChain(uint256 chainId) external onlyOwner {
        supportedChains[chainId] = true;
        emit ChainAdded(chainId);
    }

    function removeChain(uint256 chainId) external onlyOwner {
        supportedChains[chainId] = false;
        emit ChainRemoved(chainId);
    }

    function addValidator(address validator) external onlyOwner {
        if (validator == address(0)) revert InvalidValidator();
        if (validators[validator]) revert InvalidValidator();
        if (validatorCount >= MAX_VALIDATORS) revert TooManyValidators();

        validators[validator] = true;
        validatorCount++;
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyOwner {
        if (!validators[validator]) revert InvalidValidator();
        if (validatorCount <= requiredSignatures) revert InsufficientValidators();

        validators[validator] = false;
        validatorCount--;
        emit ValidatorRemoved(validator);
    }

    function configureToken(
        address token,
        uint256 targetChain,
        address remoteToken,
        bool isNative,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 dailyLimit
    ) external onlyOwner validChain(targetChain) {
        TokenConfig storage config = tokenConfigs[token];
        config.localToken = token;
        config.isNative = isNative;
        config.minimumAmount = minAmount;
        config.maximumAmount = maxAmount;
        config.dailyLimit = dailyLimit;
        config.remoteTokens[targetChain] = remoteToken;

        dailyLimits[token] = dailyLimit;
        emit TokenConfigured(token, targetChain);
    }

    function initiateTransfer(
        address token,
        uint256 amount,
        uint256 targetChain,
        address recipient
    ) external whenNotPaused validChain(targetChain) {
        TokenConfig storage config = tokenConfigs[token];
        if (config.localToken == address(0)) revert TokenNotSupported();
        if (amount < config.minimumAmount || amount > config.maximumAmount) revert InvalidAmount();

        checkAndUpdateLimit(token, amount);

        bytes32 transferId = keccak256(
            abi.encode(
                token,
                msg.sender,
                recipient,
                amount,
                targetChain,
                block.timestamp
            )
        );

        transferRequests[transferId] = TransferRequest({
            token: token,
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            targetChain: targetChain,
            timestamp: block.timestamp,
            deadline: block.timestamp + DELAY_PERIOD,
            executed: false
        });

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert InvalidAmount();

        emit TransferInitiated(
            transferId,
            token,
            msg.sender,
            recipient,
            amount,
            targetChain
        );
    }

    function approveTransfer(
        bytes32 transferId,
        bytes calldata signature
    ) external onlyValidator whenNotPaused {
        TransferRequest storage request = transferRequests[transferId];
        if (request.timestamp == 0) revert TransferNotFound();
        if (request.executed) revert TransferAlreadyExecuted();
        if (validatorApprovals[transferId][msg.sender]) revert SignatureAlreadySubmitted();

        bytes32 message = keccak256(
            abi.encodePacked(
                transferId,
                request.token,
                request.recipient,
                request.amount,
                request.targetChain
            )
        );

        address signer = recoverSigner(message, signature);
        if (signer != msg.sender) revert InvalidSignature();

        validatorApprovals[transferId][msg.sender] = true;
        approvalCounts[transferId]++;

        emit TransferApproved(transferId, msg.sender);

        if (approvalCounts[transferId] >= requiredSignatures) {
            executeTransfer(transferId);
        }
    }

    function executeTransfer(bytes32 transferId) internal {
        TransferRequest storage request = transferRequests[transferId];
        if (block.timestamp < request.deadline) revert DelayNotElapsed();
        if (approvalCounts[transferId] < requiredSignatures) revert QuorumNotReached();

        request.executed = true;

        bool success = IERC20(request.token).transfer(request.recipient, request.amount);
        if (!success) revert InvalidAmount();

        emit TransferExecuted(
            transferId,
            request.token,
            request.recipient,
            request.amount
        );
    }

    function checkAndUpdateLimit(address token, uint256 amount) internal {
        if (block.timestamp >= lastResetTime[token] + 1 days) {
            dailyUsage[token] = 0;
            lastResetTime[token] = block.timestamp;
        }

        if (dailyUsage[token] + amount > dailyLimits[token]) {
            revert DailyLimitExceeded();
        }

        dailyUsage[token] += amount;
    }

    function recoverSigner(bytes32 _hash, bytes memory _signature) internal pure returns (address) {
        require(_signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }

        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }

        address signer = ecrecover(_hash, v, r, s);
        if (signer == address(0)) {
            revert InvalidSignature();
        }

        return signer;
    }

    function emergencyWithdraw(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner whenPaused {
        bytes32 emergencyId = keccak256(abi.encode("EMERGENCY", token, recipient, amount));
        if (approvalCounts[emergencyId] < requiredSignatures) revert QuorumNotReached();

        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) revert InvalidAmount();

        emit EmergencyWithdrawal(token, recipient, amount);
    }
}

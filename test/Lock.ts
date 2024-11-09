
import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";

describe("SecureCrossChainBridge", function () {
    let bridge: Contract;
    let bridgeToken: Contract;
    let owner: any;
    let user: any;
    let validators: any[];
    let recipient: any;
    
    const CHAIN_ID_1 = 1; // Ethereum
    const CHAIN_ID_2 = 56; // BSC
    const REQUIRED_SIGNATURES = 3;
    const INITIAL_SUPPLY = ethers.parseEther("1000000");
    const BRIDGE_AMOUNT = ethers.parseEther("100");
    const MIN_AMOUNT = ethers.parseEther("10");
    const MAX_AMOUNT = ethers.parseEther("1000");
    const DAILY_LIMIT = ethers.parseEther("5000");

    beforeEach(async function () {
        // Get signers
        [owner, user, recipient, ...validators] = await ethers.getSigners();

        // Deploy BridgeToken
        const BridgeToken = await ethers.getContractFactory("BridgeToken");
        bridgeToken = await BridgeToken.deploy(
            "Bridge Token",
            "BTKN",
            18
        );

        // Deploy SecureCrossChainBridge
        const Bridge = await ethers.getContractFactory("SecureCrossChainBridge");
        bridge = await Bridge.deploy(CHAIN_ID_1, REQUIRED_SIGNATURES);

        // Add target chain as supported chain
        await bridge.addChain(CHAIN_ID_2);

        // Mint tokens to user
        await bridgeToken.mint(user.address, INITIAL_SUPPLY);

        // Add validators
        for (let i = 0; i < REQUIRED_SIGNATURES; i++) {
            await bridge.addValidator(validators[i].address);
        }

        // Configure token
        await bridge.configureToken(
            await bridgeToken.getAddress(),
            CHAIN_ID_2,
            ethers.Wallet.createRandom().address, // Remote token address
            true, // isNative
            MIN_AMOUNT,
            MAX_AMOUNT,
            DAILY_LIMIT
        );

        // Approve bridge to spend tokens
        await bridgeToken.connect(user).approve(
            await bridge.getAddress(),
            BRIDGE_AMOUNT
        );
    });

    describe("Setup", function () {
        it("Should deploy bridge with correct parameters", async function () {
            const config = await bridge.bridgeConfig();
            // Access individual properties instead of using deep include
            expect(config[0]).to.equal(BigInt(CHAIN_ID_1)); // chainId
            expect(config[1]).to.equal(BigInt(REQUIRED_SIGNATURES)); // requiredConfirmations
            expect(await bridge.paused()).to.be.false;
        });

        it("Should set up validators correctly", async function () {
            for (let i = 0; i < REQUIRED_SIGNATURES; i++) {
                expect(await bridge.validators(validators[i].address)).to.be.true;
            }
            expect(await bridge.validatorCount()).to.equal(REQUIRED_SIGNATURES);
        });

        it("Should support both chains", async function () {
            expect(await bridge.supportedChains(CHAIN_ID_1)).to.be.true;
            expect(await bridge.supportedChains(CHAIN_ID_2)).to.be.true;
        });
    });

    describe("Chain Management", function () {
        it("Should allow owner to add new chain", async function () {
            const NEW_CHAIN_ID = 137; // Polygon
            await expect(bridge.addChain(NEW_CHAIN_ID))
                .to.emit(bridge, "ChainAdded")
                .withArgs(NEW_CHAIN_ID);
            expect(await bridge.supportedChains(NEW_CHAIN_ID)).to.be.true;
        });

        it("Should prevent non-owner from adding chain", async function () {
            const NEW_CHAIN_ID = 137;
            await expect(bridge.connect(user).addChain(NEW_CHAIN_ID))
                .to.be.revertedWithCustomError(bridge, "OwnableUnauthorizedAccount");
        });
    });

    describe("Pause Functionality", function () {
        it("Should allow owner to pause bridge", async function () {
            await expect(bridge.pause())
                .to.emit(bridge, "Paused")
                .withArgs(owner.address);
            expect(await bridge.paused()).to.be.true;
        });

        it("Should prevent non-owner from pausing", async function () {
            await expect(bridge.connect(user).pause())
                .to.be.revertedWithCustomError(bridge, "OwnableUnauthorizedAccount");
        });

        it("Should prevent operations when paused", async function () {
            await bridge.pause();
            await expect(
                bridge.connect(user).initiateTransfer(
                    await bridgeToken.getAddress(),
                    BRIDGE_AMOUNT,
                    CHAIN_ID_2,
                    recipient.address
                )
            ).to.be.revertedWithCustomError(bridge, "BridgePaused");
        });
    });

    describe("Token Configuration", function () {
        it("Should configure token correctly", async function () {
            const tokenAddress = await bridgeToken.getAddress();
            const config = await bridge.tokenConfigs(tokenAddress);
            expect(config.localToken).to.equal(tokenAddress);
            expect(config.isNative).to.be.true;
            expect(config.minimumAmount).to.equal(MIN_AMOUNT);
            expect(config.maximumAmount).to.equal(MAX_AMOUNT);
            expect(config.dailyLimit).to.equal(DAILY_LIMIT);
        });

        it("Should prevent configuring token for unsupported chain", async function () {
            const UNSUPPORTED_CHAIN = 999;
            await expect(
                bridge.configureToken(
                    await bridgeToken.getAddress(),
                    UNSUPPORTED_CHAIN,
                    ethers.Wallet.createRandom().address,
                    true,
                    MIN_AMOUNT,
                    MAX_AMOUNT,
                    DAILY_LIMIT
                )
            ).to.be.revertedWithCustomError(bridge, "ChainNotSupported");
        });
    });

    describe("Transfer Process", function () {
        it("Should initiate transfer correctly", async function () {
            const tx = await bridge.connect(user).initiateTransfer(
                await bridgeToken.getAddress(),
                BRIDGE_AMOUNT,
                CHAIN_ID_2,
                recipient.address
            );

            const receipt = await tx.wait();
            // Changed event finding logic
            const transferEvent = receipt.logs.find(
                (log) => {
                    try {
                        const parsed = bridge.interface.parseLog(log);
                        return parsed?.name === 'TransferInitiated';
                    } catch {
                        return false;
                    }
                }
            );
            const parsedEvent = bridge.interface.parseLog(transferEvent);
            expect(parsedEvent.name).to.equal('TransferInitiated');

            // Get transferId from parsed event
            const transferId = parsedEvent.args[0];
            
            // Check transfer request details
            const request = await bridge.transferRequests(transferId);
            expect(request.token).to.equal(await bridgeToken.getAddress());
            expect(request.amount).to.equal(BRIDGE_AMOUNT);
            expect(request.sender).to.equal(user.address);
            expect(request.recipient).to.equal(recipient.address);
            expect(request.executed).to.be.false;
        });

        

        

        
    });
});

import {
  loadFixture,
  time,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

// Define enums to match the contract
enum CampaignStatus {
  PUBLISHED,
  FULFILLED,
  DISCARDED,
}

describe("Marketplace", function () {
  // We define a fixture to reuse the same setup in every test
  async function deployMarketplaceFixture() {
    const PLATFORM_FEES = 10_000; // 10%

    // Get signers
    const [owner, creator, kol, otherAccount] = await hre.ethers.getSigners();

    // Deploy mock ERC20 token for testing
    const MockToken = await hre.ethers.getContractFactory("MockERC20");
    const mockToken = await MockToken.deploy("Mock Token", "MTK");

    // Deploy contract
    const Marketplace = await hre.ethers.getContractFactory("Marketplace");
    const marketplace = await Marketplace.deploy();

    // Mint tokens to creator for testing
    await mockToken.mint(creator.address, hre.ethers.parseEther("1000"));
    await mockToken.mint(kol.address, hre.ethers.parseEther("1000"));

    return {
      marketplace,
      mockToken,
      owner,
      creator,
      kol,
      otherAccount,
      PLATFORM_FEES,
    };
  }

  // Add this right after deployMarketplaceFixture
  async function setupTargetedCampaignTest() {
    const fixture = await loadFixture(deployMarketplaceFixture);
    const { marketplace, mockToken, creator, kol } = fixture;

    const currentTime = Math.floor(Date.now() / 1000);
    const campaignData = {
      selectedKol: kol.address,
      offeringAmount: hre.ethers.parseEther("1"),
      offerEndsIn: currentTime + 7 * 24 * 60 * 60, // 7 days from now
      tokenAddress: mockToken.target,
    };

    // Approve tokens for marketplace
    await mockToken
      .connect(creator)
      .approve(marketplace.target, campaignData.offeringAmount);

    return { ...fixture, campaignData };
  }

  async function setupPublicCampaignTest() {
    const fixture = await loadFixture(deployMarketplaceFixture);
    const { marketplace, mockToken, creator } = fixture;

    const currentTime = Math.floor(Date.now() / 1000);
    const campaignData = {
      offerEndsIn: currentTime + 7 * 24 * 60 * 60, // 7 days from now
      poolAmount: hre.ethers.parseEther("1"),
      tokenAddress: mockToken.target,
    };

    // Approve tokens for marketplace
    await mockToken
      .connect(creator)
      .approve(marketplace.target, campaignData.poolAmount);

    return { ...fixture, campaignData };
  }

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      const { marketplace, owner } = await loadFixture(
        deployMarketplaceFixture
      );
      expect(await marketplace.owner()).to.equal(owner.address);
    });

    it("Should set the correct initial platform fees", async function () {
      const { marketplace, PLATFORM_FEES } = await loadFixture(
        deployMarketplaceFixture
      );
      expect(await marketplace.platformFeesPercentage()).to.equal(
        PLATFORM_FEES
      );
    });
  });

  describe("Targeted Campaign Management", function () {
    let marketplace: any;
    let mockToken: any;
    let creator: any;
    let kol: any;
    let owner: any;
    let campaignData: any;
    let campaignId: any;

    beforeEach(async function () {
      const setup = await setupTargetedCampaignTest();
      marketplace = setup.marketplace;
      mockToken = setup.mockToken;
      owner = setup.owner;
      kol = setup.kol;
      creator = setup.creator;
      campaignData = setup.campaignData;

      // Create targeted campaign
      const tx = await marketplace
        .connect(creator)
        .createTargetedCampaign(
          campaignData.selectedKol,
          campaignData.offeringAmount,
          campaignData.offerEndsIn,
          campaignData.tokenAddress
        );

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log: any) => log.fragment && log.fragment.name === "CampaignCreated"
      );
      campaignId = event.args[0];
    });

    it("Should create a new targeted campaign", async function () {
      const campaigns = await marketplace.getAllTargetedCampaigns();
      expect(campaigns.length).to.equal(1);
    });

    it("Should emit CampaignCreated event", async function () {
      const campaigns = await marketplace.getAllTargetedCampaigns();
      expect(campaigns[0]).to.equal(campaignId);
    });

    it("Should set correct campaign status after creation", async function () {
      const campaign = await marketplace.getTargetedCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.PUBLISHED);
    });

    it("Should allow creator to update targeted campaign", async function () {
      const newAmount = hre.ethers.parseEther("2");
      await mockToken.connect(creator).approve(marketplace.target, newAmount);

      await expect(
        marketplace
          .connect(creator)
          .updateTargetedCampaign(
            campaignId,
            kol.address,
            campaignData.offerEndsIn + 1000,
            newAmount
          )
      )
        .to.emit(marketplace, "CampaignUpdated")
        .withArgs(campaignId, creator.address);

      const updatedCampaign = await marketplace.getTargetedCampaignInfo(
        campaignId
      );
      expect(updatedCampaign.amountOffered).to.equal(newAmount);
    });

    it("Should allow selected KOL to fulfill targeted campaign", async function () {
      const kolBalanceBefore = await mockToken.balanceOf(kol.address);

      await expect(marketplace.connect(kol).fulfilTargetedCampaign(campaignId))
        .to.emit(marketplace, "CampaignFulfilled")
        .withArgs(campaignId, kol.address);

      const campaign = await marketplace.getTargetedCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.FULFILLED);

      // Check KOL received payment (minus platform fees)
      const kolBalanceAfter = await mockToken.balanceOf(kol.address);
      const platformFees =
        (campaignData.offeringAmount * BigInt(10000)) / BigInt(100000);
      const expectedPayment = campaignData.offeringAmount - platformFees;
      expect(kolBalanceAfter - kolBalanceBefore).to.equal(expectedPayment);
    });

    it("Should allow creator to discard targeted campaign", async function () {
      const creatorBalanceBefore = await mockToken.balanceOf(creator.address);

      await expect(
        marketplace.connect(creator).discardTargetedCampaign(campaignId)
      )
        .to.emit(marketplace, "CampaignDiscarded")
        .withArgs(campaignId, creator.address);

      const campaign = await marketplace.getTargetedCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.DISCARDED);

      // Check creator received refund
      const creatorBalanceAfter = await mockToken.balanceOf(creator.address);
      expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(
        campaignData.offeringAmount
      );
    });

    describe("Targeted Campaign Edge Cases and Failures", function () {
      it("Should fail when non-selected KOL tries to fulfill campaign", async function () {
        await expect(
          marketplace.connect(creator).fulfilTargetedCampaign(campaignId)
        ).to.be.revertedWithCustomError(marketplace, "Unauthorized");
      });

      it("Should fail to fulfill already fulfilled campaign", async function () {
        await marketplace.connect(kol).fulfilTargetedCampaign(campaignId);

        await expect(
          marketplace.connect(kol).fulfilTargetedCampaign(campaignId)
        )
          .to.be.revertedWithCustomError(marketplace, "InvalidCampaignStatus")
          .withArgs(CampaignStatus.PUBLISHED, CampaignStatus.FULFILLED);
      });

      it("Should fail to fulfill expired campaign", async function () {
        await time.increaseTo(campaignData.offerEndsIn + 1);

        await expect(
          marketplace.connect(kol).fulfilTargetedCampaign(campaignId)
        ).to.be.revertedWithCustomError(marketplace, "CampaignExpired");
      });

      it("Should fail when non-creator tries to discard campaign", async function () {
        await expect(
          marketplace.connect(kol).discardTargetedCampaign(campaignId)
        ).to.be.revertedWithCustomError(marketplace, "Unauthorized");
      });
    });
  });

  describe("Public Campaign Management", function () {
    let marketplace: any;
    let mockToken: any;
    let creator: any;
    let owner: any;
    let campaignData: any;
    let campaignId: any;

    beforeEach(async function () {
      const setup = await setupPublicCampaignTest();
      marketplace = setup.marketplace;
      mockToken = setup.mockToken;
      owner = setup.owner;
      creator = setup.creator;
      campaignData = setup.campaignData;

      // Create public campaign
      const tx = await marketplace
        .connect(creator)
        .createPublicCampaign(
          campaignData.offerEndsIn,
          campaignData.poolAmount,
          campaignData.tokenAddress
        );

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log: any) =>
          log.fragment && log.fragment.name === "OpenCampaignCreated"
      );
      campaignId = event.args[0];
    });

    it("Should create a new public campaign", async function () {
      const campaigns = await marketplace.getAllPublicCampaigns();
      expect(campaigns.length).to.equal(1);
    });

    it("Should emit OpenCampaignCreated event", async function () {
      const campaigns = await marketplace.getAllPublicCampaigns();
      expect(campaigns[0]).to.equal(campaignId);
    });

    it("Should set correct campaign status after creation", async function () {
      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.PUBLISHED);
    });

    it("Should allow creator to complete public campaign as fulfilled", async function () {
      await expect(
        marketplace.connect(creator).completePublicCampaign(campaignId, true)
      )
        .to.emit(marketplace, "OpenCampaignCompleted")
        .withArgs(campaignId, creator.address, true);

      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.FULFILLED);
    });

    it("Should allow creator to complete public campaign as discarded", async function () {
      await expect(
        marketplace.connect(creator).completePublicCampaign(campaignId, false)
      )
        .to.emit(marketplace, "OpenCampaignCompleted")
        .withArgs(campaignId, creator.address, false);

      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.DISCARDED);
    });

    it("Should allow creator to discard public campaign", async function () {
      const creatorBalanceBefore = await mockToken.balanceOf(creator.address);

      await expect(
        marketplace.connect(creator).discardPublicCampaign(campaignId)
      )
        .to.emit(marketplace, "OpenCampaignDiscarded")
        .withArgs(campaignId, creator.address);

      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.DISCARDED);

      // Check creator received refund
      const creatorBalanceAfter = await mockToken.balanceOf(creator.address);
      expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(
        campaignData.poolAmount
      );
    });

    it("Should handle public campaign update with reduced amount", async function () {
      const newAmount = hre.ethers.parseEther("0.5");
      const creatorBalanceBefore = await mockToken.balanceOf(creator.address);

      await expect(
        marketplace
          .connect(creator)
          .updatePublicCampaign(
            campaignId,
            campaignData.offerEndsIn + 1000,
            newAmount,
            CampaignStatus.PUBLISHED
          )
      )
        .to.emit(marketplace, "OpenCampaignUpdated")
        .withArgs(campaignId, creator.address);

      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.poolAmount).to.equal(newAmount);

      // Check creator received refund for reduced amount
      const creatorBalanceAfter = await mockToken.balanceOf(creator.address);
      const refundAmount = campaignData.poolAmount - newAmount;
      expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(refundAmount);
    });

    it("Should handle public campaign update with increased amount", async function () {
      const newAmount = hre.ethers.parseEther("2");
      await mockToken
        .connect(creator)
        .approve(marketplace.target, newAmount - campaignData.poolAmount);

      await expect(
        marketplace
          .connect(creator)
          .updatePublicCampaign(
            campaignId,
            campaignData.offerEndsIn + 1000,
            newAmount,
            CampaignStatus.PUBLISHED
          )
      )
        .to.emit(marketplace, "OpenCampaignUpdated")
        .withArgs(campaignId, creator.address);

      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.poolAmount).to.equal(newAmount);
    });

    it("Should handle public campaign finalization without double-spending", async function () {
      const ownerBalanceBefore = await mockToken.balanceOf(owner.address);

      // First update to reduce amount (should refund creator)
      const reducedAmount = hre.ethers.parseEther("0.5");
      await marketplace
        .connect(creator)
        .updatePublicCampaign(
          campaignId,
          campaignData.offerEndsIn + 1000,
          reducedAmount,
          CampaignStatus.FULFILLED
        );

      // Check that owner only received the reduced amount, not the original amount
      const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
      expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(reducedAmount);

      // Verify the campaign is finalized
      const campaign = await marketplace.getPublicCampaignInfo(campaignId);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.FULFILLED);
      expect(campaign.poolAmount).to.equal(reducedAmount);
    });

    describe("Public Campaign Edge Cases and Failures", function () {
      it("Should fail when non-creator tries to complete campaign", async function () {
        const [otherAccount] = await hre.ethers.getSigners();
        await expect(
          marketplace
            .connect(otherAccount)
            .completePublicCampaign(campaignId, true)
        ).to.be.revertedWithCustomError(marketplace, "Unauthorized");
      });

      it("Should fail to complete already completed campaign", async function () {
        await marketplace
          .connect(creator)
          .completePublicCampaign(campaignId, true);

        await expect(
          marketplace.connect(creator).completePublicCampaign(campaignId, true)
        )
          .to.be.revertedWithCustomError(marketplace, "InvalidCampaignStatus")
          .withArgs(CampaignStatus.PUBLISHED, CampaignStatus.FULFILLED);
      });

      it("Should fail to complete expired campaign", async function () {
        await time.increaseTo(campaignData.offerEndsIn + 1);

        await expect(
          marketplace.connect(creator).completePublicCampaign(campaignId, true)
        ).to.be.revertedWithCustomError(marketplace, "CampaignExpired");
      });
    });
  });

  describe("Platform Management", function () {
    let marketplace: any;
    let owner: any;

    beforeEach(async function () {
      const setup = await loadFixture(deployMarketplaceFixture);
      marketplace = setup.marketplace;
      owner = setup.owner;
    });

    it("Should allow owner to update platform fees", async function () {
      const newFees = 15_000; // 15%

      await expect(marketplace.updatePlatformFees(newFees))
        .to.emit(marketplace, "PlatformFeesUpdated")
        .withArgs(10_000, newFees);

      expect(await marketplace.platformFeesPercentage()).to.equal(newFees);
    });

    it("Should allow owner to pause and unpause", async function () {
      await expect(marketplace.pause())
        .to.emit(marketplace, "Paused")
        .withArgs(owner.address);

      await expect(marketplace.unpause())
        .to.emit(marketplace, "Unpaused")
        .withArgs(owner.address);
    });

    it("Should allow owner to withdraw tokens", async function () {
      const { mockToken, creator } = await loadFixture(
        deployMarketplaceFixture
      );

      // Transfer some tokens to marketplace
      await mockToken
        .connect(creator)
        .transfer(marketplace.target, hre.ethers.parseEther("1"));

      const ownerBalanceBefore = await mockToken.balanceOf(owner.address);

      await expect(marketplace.withdrawToken(mockToken.target)).to.not.be
        .reverted;

      const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
      expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(
        hre.ethers.parseEther("1")
      );
    });
  });

  describe("Getter Functions", function () {
    let marketplace: any;
    let mockToken: any;
    let creator: any;
    let kol: any;

    beforeEach(async function () {
      const setup = await setupTargetedCampaignTest();
      marketplace = setup.marketplace;
      mockToken = setup.mockToken;
      creator = setup.creator;
      kol = setup.kol;
    });

    it("Should return all targeted campaigns", async function () {
      await marketplace
        .connect(creator)
        .createTargetedCampaign(
          kol.address,
          hre.ethers.parseEther("1"),
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          mockToken.target
        );

      const campaigns = await marketplace.getAllTargetedCampaigns();
      expect(campaigns).to.have.lengthOf(1);
    });

    it("Should return all public campaigns", async function () {
      await marketplace
        .connect(creator)
        .createPublicCampaign(
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          hre.ethers.parseEther("1"),
          mockToken.target
        );

      const campaigns = await marketplace.getAllPublicCampaigns();
      expect(campaigns).to.have.lengthOf(1);
    });

    it("Should return user's targeted campaigns", async function () {
      await marketplace
        .connect(creator)
        .createTargetedCampaign(
          kol.address,
          hre.ethers.parseEther("1"),
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          mockToken.target
        );

      const userCampaigns = await marketplace.getUserTargetedCampaigns(
        creator.address
      );
      expect(userCampaigns).to.have.lengthOf(1);
    });

    it("Should return user's public campaigns", async function () {
      await marketplace
        .connect(creator)
        .createPublicCampaign(
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          hre.ethers.parseEther("1"),
          mockToken.target
        );

      const userCampaigns = await marketplace.getUserPublicCampaigns(
        creator.address
      );
      expect(userCampaigns).to.have.lengthOf(1);
    });

    it("Should return correct targeted campaign info", async function () {
      const offeringAmount = hre.ethers.parseEther("1");
      const offerEndsIn = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60;

      await marketplace
        .connect(creator)
        .createTargetedCampaign(
          kol.address,
          offeringAmount,
          offerEndsIn,
          mockToken.target
        );

      const campaigns = await marketplace.getAllTargetedCampaigns();
      const campaign = await marketplace.getTargetedCampaignInfo(campaigns[0]);

      expect(campaign.selectedKol).to.equal(kol.address);
      expect(campaign.amountOffered).to.equal(offeringAmount);
      expect(campaign.offerEndsIn).to.equal(offerEndsIn);
      expect(campaign.creatorAddress).to.equal(creator.address);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.PUBLISHED);
      expect(campaign.tokenAddress).to.equal(mockToken.target);
    });

    it("Should return correct public campaign info", async function () {
      const poolAmount = hre.ethers.parseEther("1");
      const offerEndsIn = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60;

      await marketplace
        .connect(creator)
        .createPublicCampaign(offerEndsIn, poolAmount, mockToken.target);

      const campaigns = await marketplace.getAllPublicCampaigns();
      const campaign = await marketplace.getPublicCampaignInfo(campaigns[0]);

      expect(campaign.poolAmount).to.equal(poolAmount);
      expect(campaign.offerEndsIn).to.equal(offerEndsIn);
      expect(campaign.creatorAddress).to.equal(creator.address);
      expect(campaign.campaignStatus).to.equal(CampaignStatus.PUBLISHED);
      expect(campaign.tokenAddress).to.equal(mockToken.target);
    });

    it("Should check if targeted campaign exists", async function () {
      await marketplace
        .connect(creator)
        .createTargetedCampaign(
          kol.address,
          hre.ethers.parseEther("1"),
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          mockToken.target
        );

      const campaigns = await marketplace.getAllTargetedCampaigns();
      expect(await marketplace.targetedCampaignExists(campaigns[0])).to.be.true;
      expect(
        await marketplace.targetedCampaignExists(
          "0x1234567890123456789012345678901234567890123456789012345678901234"
        )
      ).to.be.false;
    });

    it("Should check if public campaign exists", async function () {
      await marketplace
        .connect(creator)
        .createPublicCampaign(
          Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
          hre.ethers.parseEther("1"),
          mockToken.target
        );

      const campaigns = await marketplace.getAllPublicCampaigns();
      expect(await marketplace.publicCampaignExists(campaigns[0])).to.be.true;
      expect(
        await marketplace.publicCampaignExists(
          "0x1234567890123456789012345678901234567890123456789012345678901234"
        )
      ).to.be.false;
    });
  });
});

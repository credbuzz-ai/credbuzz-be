// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

struct Campaign {
    bytes32 id;
    uint256 createdAt;
    address creatorAddress;
    address selectedKol;
    uint256 offerEndsIn;
    uint256 amountOffered;
    address tokenAddress;
    CampaignStatus campaignStatus;
}

struct OpenCampaign {
    bytes32 id;
    address creatorAddress;
    uint256 offerEndsIn;
    uint256 poolAmount;
    CampaignStatus campaignStatus;
    address tokenAddress;
}

enum CampaignStatus {
    PUBLISHED,
    FULFILLED,
    DISCARDED
}

// ------------------ ERRORS ------------------
// FUND ERRORS
error InsufficientFundsError(uint256 requiredFunds, uint256 sentFunds);
error FundTransferError();
error ContractBalanceInsufficient(uint256 required, uint256 available);

// AUTHORIZATION ERRORS
error Unauthorized();
error InvalidOwnerAddress();

// CAMPAIGN ERRORS
error InvalidCampaignStatus(CampaignStatus expected, CampaignStatus actual);
error CampaignExpired(uint256 deadline, uint256 currentTime);
error CampaignNotFound(bytes32 campaignId);

// INPUT VALIDATION ERRORS
error InvalidAddress(address provided);
error InvalidAmount(uint256 amount);
error InvalidDeadline(uint256 deadline, uint256 currentTime);
error InvalidTokenAddress(address tokenAddress);
error AmountTooLarge(uint256 amount, uint256 maxAmount);

contract Marketplace is Ownable, ReentrancyGuard, Pausable {
    // ------------------ GLOBAL CONSTANTS ------------------
    uint256 public platformFeesPercentage; // 10_000 = 10%
    uint256 public constant divider = 100_000;
    uint256 public constant MAX_AMOUNT = 1e30; // Reasonable upper bound

    // ------------------ VARIABLES ------------------
    bytes32[] allCampaigns;
    mapping(address => bytes32[]) userCampaigns;
    mapping(bytes32 => Campaign) campaignInfo;

    // Open campaigns
    bytes32[] allOpenCampaigns;
    mapping(address => bytes32[]) userOpenCampaigns;
    mapping(bytes32 => OpenCampaign) openCampaignInfo;

    // ------------------ EVENTS ------------------
    // PLATFORM EVENTS
    event PlatformFeesUpdated(uint256 previousFees, uint256 updatedFees);

    // CAMPAIGN EVENTS
    event CampaignCreated(
        bytes32 indexed campaignId,
        address user,
        uint256 amount
    );
    event CampaignFulfilled(bytes32 indexed campaignId, address fulfilledBy);
    event CampaignDiscarded(bytes32 indexed campaignId, address discardedBy);
    event CampaignUpdated(bytes32 indexed campaignId, address updatedBy);

    // Open campaign events
    event OpenCampaignCreated(
        bytes32 indexed campaignId,
        address user,
        uint256 poolAmount
    );
    event OpenCampaignCompleted(
        bytes32 indexed campaignId,
        address completedBy,
        bool isFulfilled
    );
    event OpenCampaignDiscarded(
        bytes32 indexed campaignId,
        address discardedBy
    );
    event OpenCampaignUpdated(bytes32 indexed campaignId, address updatedBy);

    // ------------------ CONSTRUCTOR ------------------
    constructor() Ownable(msg.sender) {
        platformFeesPercentage = 10_000;
    }

    // ------------------ OWNER FUNCTIONS ------------------
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawToken(
        address tokenAddress
    ) external onlyOwner whenNotPaused {
        if (tokenAddress == address(0)) {
            revert InvalidTokenAddress(tokenAddress);
        }

        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        if (balance == 0) {
            revert InsufficientFundsError(1, 0);
        }

        bool success = IERC20(tokenAddress).transfer(owner(), balance);
        if (!success) {
            revert FundTransferError();
        }
    }

    function withdrawEth() external onlyOwner whenNotPaused {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert InsufficientFundsError(1, 0);
        }

        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) {
            revert FundTransferError();
        }
    }

    function updatePlatformFees(
        uint256 newFees
    ) external onlyOwner whenNotPaused {
        if (newFees > divider) {
            revert InvalidAmount(newFees);
        }

        uint256 oldFees = platformFeesPercentage;
        platformFeesPercentage = newFees;

        emit PlatformFeesUpdated(oldFees, newFees);
    }

    // ------------------ TARGETED CAMPAIGN FUNCTIONS ------------------
    function createTargetedCampaign(
        address selectedKol,
        uint256 offeringAmount,
        uint256 offerEndsIn,
        address tokenAddress
    ) external nonReentrant whenNotPaused {
        // Input validation
        if (selectedKol == address(0)) {
            revert InvalidAddress(selectedKol);
        }
        if (offeringAmount == 0) {
            revert InvalidAmount(offeringAmount);
        }
        if (offeringAmount > MAX_AMOUNT) {
            revert AmountTooLarge(offeringAmount, MAX_AMOUNT);
        }
        if (tokenAddress == address(0)) {
            revert InvalidTokenAddress(tokenAddress);
        }

        uint256 currentTime = block.timestamp;
        if (offerEndsIn <= currentTime) {
            revert InvalidDeadline(offerEndsIn, currentTime);
        }

        // Check allowance and transfer tokens
        IERC20 token = IERC20(tokenAddress);
        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < offeringAmount) {
            revert InsufficientFundsError(offeringAmount, allowance);
        }

        // Transfer tokens from creator to contract
        bool transferSuccess = token.transferFrom(
            msg.sender,
            address(this),
            offeringAmount
        );
        if (!transferSuccess) {
            revert FundTransferError();
        }

        bytes32 id = keccak256(
            abi.encode(
                msg.sender,
                selectedKol,
                offeringAmount,
                currentTime,
                block.number,
                block.timestamp,
                blockhash(block.number - 1),
                block.gaslimit,
                block.coinbase
            )
        );

        Campaign memory campaign = Campaign({
            id: id,
            createdAt: currentTime,
            creatorAddress: msg.sender,
            selectedKol: selectedKol,
            offerEndsIn: offerEndsIn,
            amountOffered: offeringAmount,
            tokenAddress: tokenAddress,
            campaignStatus: CampaignStatus.PUBLISHED
        });

        campaignInfo[id] = campaign;
        allCampaigns.push(id);
        userCampaigns[msg.sender].push(id);

        emit CampaignCreated(id, msg.sender, offeringAmount);
    }

    function updateTargetedCampaign(
        bytes32 campaignId,
        address selectedKol,
        uint256 offerEndsIn,
        uint256 newAmountOffered
    ) external nonReentrant whenNotPaused {
        // Input validation
        if (selectedKol == address(0)) {
            revert InvalidAddress(selectedKol);
        }
        if (newAmountOffered == 0) {
            revert InvalidAmount(newAmountOffered);
        }
        if (newAmountOffered > MAX_AMOUNT) {
            revert AmountTooLarge(newAmountOffered, MAX_AMOUNT);
        }

        uint256 currentTime = block.timestamp;
        if (offerEndsIn <= currentTime) {
            revert InvalidDeadline(offerEndsIn, currentTime);
        }

        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }

        if (campaign.campaignStatus != CampaignStatus.PUBLISHED) {
            revert InvalidCampaignStatus(
                CampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        uint256 oldAmount = campaign.amountOffered;

        campaign.selectedKol = selectedKol;
        campaign.offerEndsIn = offerEndsIn;
        campaign.amountOffered = newAmountOffered;

        IERC20 token = IERC20(campaign.tokenAddress);

        if (oldAmount > newAmountOffered) {
            // Refund excess amount
            uint256 refundAmount = oldAmount - newAmountOffered;
            if (token.balanceOf(address(this)) < refundAmount) {
                revert ContractBalanceInsufficient(
                    refundAmount,
                    token.balanceOf(address(this))
                );
            }

            bool success = token.transfer(
                campaign.creatorAddress,
                refundAmount
            );
            if (!success) {
                revert FundTransferError();
            }
        } else if (newAmountOffered > oldAmount) {
            // Collect additional amount
            uint256 additionalAmount = newAmountOffered - oldAmount;
            uint256 allowance = token.allowance(msg.sender, address(this));
            if (allowance < additionalAmount) {
                revert InsufficientFundsError(additionalAmount, allowance);
            }

            bool success = token.transferFrom(
                msg.sender,
                address(this),
                additionalAmount
            );
            if (!success) {
                revert FundTransferError();
            }
        }

        emit CampaignUpdated(campaignId, msg.sender);
    }

    function fulfilTargetedCampaign(
        bytes32 campaignId
    ) external nonReentrant whenNotPaused {
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }

        // Authorization: Only selected KOL or owner can fulfill
        if (campaign.selectedKol != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        if (campaign.campaignStatus != CampaignStatus.PUBLISHED) {
            revert InvalidCampaignStatus(
                CampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        // Check if offer deadline has passed
        if (block.timestamp > campaign.offerEndsIn) {
            revert CampaignExpired(campaign.offerEndsIn, block.timestamp);
        }

        uint256 campaignOffering = campaign.amountOffered;
        uint256 platformFees = (campaignOffering * platformFeesPercentage) /
            divider;
        uint256 amountToPayKol = campaignOffering - platformFees;

        IERC20 token = IERC20(campaign.tokenAddress);

        // Check balance for both transfers combined
        uint256 totalRequired = amountToPayKol + platformFees;
        if (token.balanceOf(address(this)) < totalRequired) {
            revert ContractBalanceInsufficient(
                totalRequired,
                token.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.FULFILLED;

        bool kolTransfer = token.transfer(campaign.selectedKol, amountToPayKol);
        if (!kolTransfer) {
            revert FundTransferError();
        }

        bool ownerTransfer = token.transfer(owner(), platformFees);
        if (!ownerTransfer) {
            revert FundTransferError();
        }

        emit CampaignFulfilled(campaignId, msg.sender);
    }

    function discardTargetedCampaign(
        bytes32 campaignId
    ) external nonReentrant whenNotPaused {
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        if (campaign.campaignStatus != CampaignStatus.PUBLISHED) {
            revert InvalidCampaignStatus(
                CampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        uint256 amountToReturn = campaign.amountOffered;
        IERC20 token = IERC20(campaign.tokenAddress);

        if (token.balanceOf(address(this)) < amountToReturn) {
            revert ContractBalanceInsufficient(
                amountToReturn,
                token.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.DISCARDED;

        bool success = token.transfer(campaign.creatorAddress, amountToReturn);
        if (!success) {
            revert FundTransferError();
        }

        emit CampaignDiscarded(campaignId, msg.sender);
    }

    // ------------------ PUBLIC CAMPAIGN FUNCTIONS ------------------
    function createPublicCampaign(
        uint256 offerEndsIn,
        uint256 poolAmount,
        address tokenAddress
    ) external nonReentrant whenNotPaused {
        // Input validation
        if (poolAmount == 0) {
            revert InvalidAmount(poolAmount);
        }
        if (poolAmount > MAX_AMOUNT) {
            revert AmountTooLarge(poolAmount, MAX_AMOUNT);
        }
        if (tokenAddress == address(0)) {
            revert InvalidTokenAddress(tokenAddress);
        }

        uint256 currentTime = block.timestamp;
        if (offerEndsIn <= currentTime) {
            revert InvalidDeadline(offerEndsIn, currentTime);
        }

        // Check allowance and transfer tokens
        IERC20 token = IERC20(tokenAddress);
        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < poolAmount) {
            revert InsufficientFundsError(poolAmount, allowance);
        }

        // Transfer tokens from creator to contract
        bool transferSuccess = token.transferFrom(
            msg.sender,
            address(this),
            poolAmount
        );
        if (!transferSuccess) {
            revert FundTransferError();
        }

        bytes32 id = keccak256(
            abi.encode(
                msg.sender,
                poolAmount,
                currentTime,
                block.number,
                block.timestamp,
                blockhash(block.number - 1),
                block.gaslimit,
                block.coinbase
            )
        );

        OpenCampaign memory campaign = OpenCampaign({
            id: id,
            creatorAddress: msg.sender,
            offerEndsIn: offerEndsIn,
            poolAmount: poolAmount,
            campaignStatus: CampaignStatus.PUBLISHED,
            tokenAddress: tokenAddress
        });

        openCampaignInfo[id] = campaign;
        allOpenCampaigns.push(id);
        userOpenCampaigns[msg.sender].push(id);

        emit OpenCampaignCreated(id, msg.sender, poolAmount);
    }

    function completePublicCampaign(
        bytes32 campaignId,
        bool isFulfilled
    ) external nonReentrant whenNotPaused {
        OpenCampaign storage campaign = openCampaignInfo[campaignId];

        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }

        if (campaign.campaignStatus != CampaignStatus.PUBLISHED) {
            revert InvalidCampaignStatus(
                CampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        // Check if offer deadline has passed
        if (block.timestamp > campaign.offerEndsIn) {
            revert CampaignExpired(campaign.offerEndsIn, block.timestamp);
        }

        campaign.campaignStatus = isFulfilled
            ? CampaignStatus.FULFILLED
            : CampaignStatus.DISCARDED;

        // Transfer pool amount to owner for manual distribution
        IERC20 token = IERC20(campaign.tokenAddress);
        bool success = token.transfer(owner(), campaign.poolAmount);
        if (!success) {
            revert FundTransferError();
        }

        emit OpenCampaignCompleted(campaignId, msg.sender, isFulfilled);
    }

    function discardPublicCampaign(
        bytes32 campaignId
    ) external nonReentrant whenNotPaused {
        OpenCampaign storage campaign = openCampaignInfo[campaignId];

        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        if (campaign.campaignStatus != CampaignStatus.PUBLISHED) {
            revert InvalidCampaignStatus(
                CampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        uint256 amountToReturn = campaign.poolAmount;
        IERC20 token = IERC20(campaign.tokenAddress);

        if (token.balanceOf(address(this)) < amountToReturn) {
            revert ContractBalanceInsufficient(
                amountToReturn,
                token.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.DISCARDED;

        bool success = token.transfer(campaign.creatorAddress, amountToReturn);
        if (!success) {
            revert FundTransferError();
        }

        emit OpenCampaignDiscarded(campaignId, msg.sender);
    }

    // ------------------ TARGETED CAMPAIGN GETTERS ------------------
    function getTargetedCampaignsPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory campaigns, uint256 total) {
        total = allCampaigns.length;
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        if (offset >= total) {
            campaigns = new bytes32[](0);
            return (campaigns, total);
        }

        campaigns = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            campaigns[i - offset] = allCampaigns[i];
        }
    }

    function getUserTargetedCampaigns(
        address userAddress
    ) external view returns (bytes32[] memory) {
        if (userAddress == address(0)) {
            revert InvalidAddress(userAddress);
        }
        return userCampaigns[userAddress];
    }

    function getTargetedCampaignInfo(
        bytes32 campaignId
    ) external view returns (Campaign memory) {
        Campaign memory campaign = campaignInfo[campaignId];
        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }
        return campaign;
    }

    function targetedCampaignExists(
        bytes32 campaignId
    ) external view returns (bool) {
        return campaignInfo[campaignId].creatorAddress != address(0);
    }

    function isTargetedCampaignExpired(
        bytes32 campaignId
    ) external view returns (bool) {
        Campaign memory campaign = campaignInfo[campaignId];
        if (campaign.creatorAddress == address(0)) {
            return false;
        }
        return block.timestamp > campaign.offerEndsIn;
    }

    // ------------------ PUBLIC CAMPAIGN GETTERS ------------------
    function getPublicCampaignsPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory campaigns, uint256 total) {
        total = allOpenCampaigns.length;
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        if (offset >= total) {
            campaigns = new bytes32[](0);
            return (campaigns, total);
        }

        campaigns = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            campaigns[i - offset] = allOpenCampaigns[i];
        }
    }

    function getUserPublicCampaigns(
        address userAddress
    ) external view returns (bytes32[] memory) {
        if (userAddress == address(0)) {
            revert InvalidAddress(userAddress);
        }
        return userOpenCampaigns[userAddress];
    }

    function getPublicCampaignInfo(
        bytes32 campaignId
    ) external view returns (OpenCampaign memory) {
        OpenCampaign memory campaign = openCampaignInfo[campaignId];
        if (campaign.creatorAddress == address(0)) {
            revert CampaignNotFound(campaignId);
        }
        return campaign;
    }

    function publicCampaignExists(
        bytes32 campaignId
    ) external view returns (bool) {
        return openCampaignInfo[campaignId].creatorAddress != address(0);
    }

    function isPublicCampaignExpired(
        bytes32 campaignId
    ) external view returns (bool) {
        OpenCampaign memory campaign = openCampaignInfo[campaignId];
        if (campaign.creatorAddress == address(0)) {
            return false;
        }
        return block.timestamp > campaign.offerEndsIn;
    }

    // ------------------ RECEIVE FUNCTION ------------------
    receive() external payable {}

    function validateToken(address tokenAddress) internal view {
        require(tokenAddress != address(0), "Zero address not allowed");
        uint256 size;
        assembly {
            size := extcodesize(tokenAddress)
        }
        require(size > 0, "Token must be a contract");
        try IERC20(tokenAddress).totalSupply() returns (uint256) {
            // Token implements ERC20 interface
        } catch {
            revert("Invalid ERC20 token");
        }
    }
}

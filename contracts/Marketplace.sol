// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct Campaign {
    bytes4 id;
    uint256 createdAt;
    address creatorAddress;
    address selectedKol;
    uint offerEndsIn;
    uint promotionEndsIn;
    uint amountOffered;
    CampaignStatus campaignStatus;
}

enum CampaignStatus {
    OPEN,
    ACCEPTED,
    FULFILLED,
    UNFULFILLED,
    DISCARDED
}

// ------------------ ERRORS ------------------
// USER ERRORS
error UserAlreadyRegistered(address userAddress);
error UserNotRegistered(address userAddress);

// FUND ERRORS
error InsufficientFundsError(uint256 requiredFunds, uint256 sentFunds);
error FundTransferError();

// AUTHORIZATION ERRORS
error Unauthorized();
error InvalidOwnerAddress();

// CAMPAIGN ERRORS
error InvalidCampaignStatus(CampaignStatus expected, CampaignStatus actual);
error CampaignDiscarded();

// New error for contract balance check
error ContractBalanceInsufficient(uint256 required, uint256 available);

contract Marketplace is Ownable, ReentrancyGuard {
    // ------------------ GLOBAL CONSTANTS ------------------
    uint256 public platformFeesPercentage; // 10_000 = 10%
    uint256 public constant divider = 100_000;
    address public immutable baseUsdcAddress =
        0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    uint256 public immutable baseUsdcDecimals = 6;

    // ------------------ VARIABLES ------------------
    address[] public allUsers;
    mapping(address => bool) isUserRegistered;

    bytes4[] allCampaigns;
    mapping(address => bytes4[]) userCampaigns;
    mapping(bytes4 => Campaign) campaignInfo;

    // ------------------ EVENTS ------------------
    // PLATFORM EVENTS
    event PlatformFeesUpdated(uint256 previousFees, uint256 updatedFees);

    // FUND EVENTS
    event FundWithdrawalSuccessful();

    // USER EVENTS
    event UserCreated(address indexed userAddress);

    // CAMPAIGN EVENTS
    event CampaignCreated(bytes4 indexed campaignId, address user);
    event CampaignAccepted(bytes4 indexed campaignId, address acceptedBy);
    event CampaignFulfilled(bytes4 campaignId);
    event ProjectPaymentReturned(bytes4 campaignId);
    event AcceptanceDeadlineReached(bytes4 campaignId);
    event CampaignUpdated(bytes4 indexed campaignId, address updatedBy);

    // ------------------ MODIFIERS ------------------

    modifier isRegisteredCheck() {
        if (!isUserRegistered[msg.sender]) {
            revert UserNotRegistered(msg.sender);
        }
        _;
    }

    modifier isNotRegisteredCheck() {
        if (isUserRegistered[msg.sender]) {
            revert UserAlreadyRegistered(msg.sender);
        }
        _;
    }

    modifier campaignNotDiscarded(bytes4 campaignId) {
        Campaign memory campaign = campaignInfo[campaignId];
        if (campaign.campaignStatus == CampaignStatus.DISCARDED) {
            revert CampaignDiscarded();
        }
        _;
    }

    // ------------------ CONSTRUCTOR ------------------
    // 10000 for 10%
    constructor() Ownable(msg.sender) {
        platformFeesPercentage = 10_000;
    }

    // ------------------ OWNER FUNCTIONS ------------------
    function updatePlatformFees(uint256 newFees) external onlyOwner {
        uint256 oldFees = platformFeesPercentage;
        platformFeesPercentage = newFees;

        emit PlatformFeesUpdated(oldFees, newFees);
    }

    function discardCampaign(
        bytes4 campaignId
    ) external onlyOwner nonReentrant campaignNotDiscarded(campaignId) {
        Campaign storage campaign = campaignInfo[campaignId];
        uint256 amountToReturn = campaign.amountOffered;
        IERC20 usdc = IERC20(baseUsdcAddress);

        if (usdc.balanceOf(owner()) < amountToReturn) {
            revert ContractBalanceInsufficient(
                amountToReturn,
                usdc.balanceOf(owner())
            );
        }

        campaign.campaignStatus = CampaignStatus.DISCARDED;

        emit CampaignUpdated(campaignId, msg.sender);
    }

    function acceptProjectCampaign(
        bytes4 campaignId
    ) external onlyOwner campaignNotDiscarded(campaignId) nonReentrant {
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.campaignStatus != CampaignStatus.OPEN) {
            revert InvalidCampaignStatus(
                CampaignStatus.OPEN,
                campaign.campaignStatus
            );
        }

        // @audit: this is a fallback check, the campaign status will need constant updation from backend & frontend handling too
        uint256 currentTime = block.timestamp;

        if (currentTime > campaign.offerEndsIn) {
            campaign.campaignStatus = CampaignStatus.DISCARDED;

            // @audit: USDC transfer need to implement here (from backend -> owner -> project creator)

            emit AcceptanceDeadlineReached(campaignId);
            emit ProjectPaymentReturned(campaignId);

            return;
        }

        campaign.campaignStatus = CampaignStatus.ACCEPTED;

        emit CampaignAccepted(campaignId, msg.sender);
    }

    function fulfilProjectCampaign(
        bytes4 campaignId
    ) external onlyOwner campaignNotDiscarded(campaignId) nonReentrant {
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.campaignStatus != CampaignStatus.ACCEPTED) {
            revert InvalidCampaignStatus(
                CampaignStatus.ACCEPTED,
                campaign.campaignStatus
            );
        }

        uint256 campaignOffering = campaign.amountOffered;
        uint256 platformFees = (campaignOffering * platformFeesPercentage) /
            divider;
        uint256 amountToPayKol = campaignOffering - platformFees;
        IERC20 usdc = IERC20(baseUsdcAddress);

        if (usdc.balanceOf(owner()) < amountToPayKol) {
            revert ContractBalanceInsufficient(
                amountToPayKol,
                usdc.balanceOf(owner())
            );
        }

        campaign.campaignStatus = CampaignStatus.FULFILLED;

        // @audit: USDC transfer need to implement here (from backend -> owner -> kol)

        emit CampaignFulfilled(campaignId);
    }

    // ------------------ USER SIGNUP ------------------

    function register() external isNotRegisteredCheck {
        isUserRegistered[msg.sender] = true;
        allUsers.push(msg.sender);
        emit UserCreated(msg.sender);
    }

    // ------------------ CAMPAIGN FUNCTIONS ------------------
    function createNewCampaign(
        address selectedKol,
        uint256 offeringAmount,
        uint256 promotionEndsIn,
        uint256 offerEndsIn
    ) external isRegisteredCheck {
        // @audit: this call could be done from frontend
        // Transfer USDC from creator to owner (Frontend -> creator -> owner)

        bytes4 id = bytes4(
            bytes32(
                keccak256(
                    abi.encodePacked(
                        msg.sender,
                        "CREATE_CAMPAIGN",
                        block.timestamp
                    )
                )
            )
        );

        uint currentTime = block.timestamp;
        Campaign memory campaign = Campaign({
            id: id,
            createdAt: currentTime,
            creatorAddress: msg.sender,
            selectedKol: selectedKol,
            offerEndsIn: offerEndsIn,
            promotionEndsIn: promotionEndsIn,
            amountOffered: offeringAmount,
            campaignStatus: CampaignStatus.OPEN
        });

        campaignInfo[id] = campaign;

        allCampaigns.push(id);

        userCampaigns[msg.sender].push(id);

        emit CampaignCreated(id, msg.sender);
    }

    function updateCampaign(
        bytes4 campaignId,
        address selectedKol,
        uint256 promotionEndsIn,
        uint256 offerEndsIn
    ) external isRegisteredCheck {
        require(selectedKol != address(0), "Invalid KOL address");
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.campaignStatus != CampaignStatus.OPEN) {
            revert InvalidCampaignStatus(
                CampaignStatus.OPEN,
                campaign.campaignStatus
            );
        }

        if (campaign.creatorAddress != msg.sender) {
            revert Unauthorized();
        }

        campaign.selectedKol = selectedKol;
        campaign.promotionEndsIn = promotionEndsIn;
        campaign.offerEndsIn = offerEndsIn;

        emit CampaignUpdated(campaignId, msg.sender);
    }

    // ------------------ GETTERS ------------------

    function getAllUsers() external view returns (address[] memory) {
        return allUsers;
    }

    function getAllCampaigns() external view returns (bytes4[] memory) {
        return allCampaigns;
    }

    function getUserCampaigns(
        address userAddress
    ) external view returns (bytes4[] memory) {
        return userCampaigns[userAddress];
    }

    function getCampaignInfo(
        bytes4 id
    ) external view returns (Campaign memory) {
        Campaign memory campaign = campaignInfo[id];
        return campaign;
    }
}

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
    uint256 offerEndsIn;
    uint256 promotionEndsIn;
    uint256 amountOffered;
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
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 public immutable baseUsdcDecimals = 6;
    mapping(uint256 => bytes4) campaignInfoDB;

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

    // ------------------ CONSTRUCTOR ------------------
    // 10000 for 10%
    constructor() Ownable(msg.sender) {
        platformFeesPercentage = 10_000;
    }

    // ------------------ OWNER FUNCTIONS ------------------
    function withdrawUsdc() external onlyOwner {
        address usdcAddress = baseUsdcAddress;
        uint256 balance = IERC20(usdcAddress).balanceOf(address(this));

        bool success = IERC20(usdcAddress).transfer(owner(), balance);
        if (!success) {
            revert FundTransferError();
        }
    }

    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;

        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) {
            revert FundTransferError();
        }
    }

    function updatePlatformFees(uint256 newFees) external onlyOwner {
        uint256 oldFees = platformFeesPercentage;
        platformFeesPercentage = newFees;

        emit PlatformFeesUpdated(oldFees, newFees);
    }

    function discardCampaign(uint idInDB) external onlyOwner nonReentrant {
        bytes4 campaignId = campaignInfoDB[idInDB];
        Campaign storage campaign = campaignInfo[campaignId];
        uint256 amountToReturn = campaign.amountOffered;
        IERC20 usdc = IERC20(baseUsdcAddress);

        if (usdc.balanceOf(address(this)) < amountToReturn) {
            revert ContractBalanceInsufficient(
                amountToReturn,
                usdc.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.DISCARDED;

        bool success = usdc.transfer(
            campaign.creatorAddress,
            campaign.amountOffered
        );
        if (!success) {
            revert FundTransferError();
        }

        emit CampaignUpdated(campaignId, msg.sender);
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
        uint256 offerEndsIn,
        uint idInDB
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

        campaignInfoDB[idInDB] = id;

        uint256 currentTime = block.timestamp;
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
        uint idInDB,
        address selectedKol,
        uint256 promotionEndsIn,
        uint256 offerEndsIn,
        uint256 newAmountOffered
    ) external isRegisteredCheck nonReentrant {
        bytes4 campaignId = campaignInfoDB[idInDB];
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

        IERC20 usdc = IERC20(baseUsdcAddress);

        if (campaign.amountOffered > newAmountOffered) {
            // return the extra
            bool success = usdc.transfer(
                campaign.creatorAddress,
                campaign.amountOffered - newAmountOffered
            );
            if (!success) {
                revert FundTransferError();
            }
        }

        emit CampaignUpdated(campaignId, msg.sender);
    }

    function acceptProjectCampaign(uint campaignIdDb) external nonReentrant {
        bytes4 campaignId = campaignInfoDB[campaignIdDb];
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.selectedKol != msg.sender) {
            revert Unauthorized();
        }

        if (campaign.campaignStatus != CampaignStatus.OPEN) {
            revert InvalidCampaignStatus(
                CampaignStatus.OPEN,
                campaign.campaignStatus
            );
        }

        campaign.campaignStatus = CampaignStatus.ACCEPTED;

        emit CampaignAccepted(campaignId, msg.sender);
    }

    function fulfilProjectCampaign(uint campaignIdDB) external nonReentrant {
        bytes4 campaignId = campaignInfoDB[campaignIdDB];
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

        if (usdc.balanceOf(address(this)) < amountToPayKol) {
            revert ContractBalanceInsufficient(
                amountToPayKol,
                usdc.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.FULFILLED;

        address usdcAddress = baseUsdcAddress;

        bool kolTransfer = IERC20(usdcAddress).transfer(
            campaign.selectedKol,
            amountToPayKol
        );
        if (!kolTransfer) {
            revert FundTransferError();
        }
        bool ownerTransfer = IERC20(usdcAddress).transfer(
            owner(),
            platformFees
        );
        if (!ownerTransfer) {
            revert FundTransferError();
        }

        emit CampaignFulfilled(campaignId);
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
        uint idInDB
    ) external view returns (Campaign memory) {
        bytes4 id = campaignInfoDB[idInDB];
        Campaign memory campaign = campaignInfo[id];
        return campaign;
    }

    receive() external payable {}
}

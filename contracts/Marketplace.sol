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
    address tokenAddress;
    CampaignStatus campaignStatus;
}

enum CampaignStatus {
    OPEN,
    ACCEPTED,
    FULFILLED,
    UNFULFILLED,
    DISCARDED
}

struct OpenCampaign {
    bytes4 id;
    address creatorAddress;
    uint256 promotionEndsIn;
    uint256 poolAmount;
    OpenCampaignStatus campaignStatus;
    address tokenAddress;
}

enum OpenCampaignStatus {
    PUBLISHED,
    FULFILLED,
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

// New error for open campaign
error InvalidOpenCampaignStatus(
    OpenCampaignStatus expected,
    OpenCampaignStatus actual
);

contract Marketplace is Ownable, ReentrancyGuard {
    // ------------------ GLOBAL CONSTANTS ------------------
    uint256 public platformFeesPercentage; // 10_000 = 10%
    uint256 public constant divider = 100_000;

    mapping(address tokenAddress => bool isTokenAllowed) public allowedTokens;
    mapping(address tokenAddress => uint256 tokenDecimals) public tokenDecimals;
    address[] public allowedTokensList;

    // ------------------ VARIABLES ------------------
    mapping(address => bool) isUserRegistered;

    bytes4[] allCampaigns;
    mapping(address => bytes4[]) userCampaigns;
    mapping(bytes4 => Campaign) campaignInfo;

    // New variables for open campaigns
    bytes4[] allOpenCampaigns;
    mapping(address => bytes4[]) userOpenCampaigns;
    mapping(bytes4 => OpenCampaign) openCampaignInfo;

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

    // New events for open campaigns
    event OpenCampaignCreated(
        bytes4 indexed campaignId,
        address user,
        uint256 poolAmount
    );
    event OpenCampaignCompleted(
        bytes4 indexed campaignId,
        address completedBy,
        bool isFulfilled
    );
    event OpenCampaignUpdated(bytes4 indexed campaignId, address updatedBy);

    // ------------------ CONSTRUCTOR ------------------
    // 10000 for 10%
    constructor() Ownable(msg.sender) {
        platformFeesPercentage = 10_000;
        // USDC Allowed by default
        allowedTokens[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = true;
        tokenDecimals[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = 18;
        allowedTokensList.push(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    }

    // ------------------ OWNER FUNCTIONS ------------------
    function addAllowedToken(
        address tokenAddress,
        uint256 decimals
    ) external onlyOwner {
        allowedTokens[tokenAddress] = true;
        tokenDecimals[tokenAddress] = decimals;
        allowedTokensList.push(tokenAddress);
    }

    function removeAllowedToken(address tokenAddress) external onlyOwner {
        allowedTokens[tokenAddress] = false;
        for (uint256 i = 0; i < allowedTokensList.length; i++) {
            if (allowedTokensList[i] == tokenAddress) {
                allowedTokensList[i] = allowedTokensList[
                    allowedTokensList.length - 1
                ];
                allowedTokensList.pop();
                break;
            }
        }
    }

    function getAllowedTokens() external view returns (address[] memory) {
        return allowedTokensList;
    }

    function withdrawToken(address tokenAddress) external onlyOwner {
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));

        bool success = IERC20(tokenAddress).transfer(owner(), balance);
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

    function discardCampaign(
        bytes4 campaignId
    ) external onlyOwner nonReentrant {
        Campaign storage campaign = campaignInfo[campaignId];
        uint256 amountToReturn = campaign.amountOffered;
        IERC20 token = IERC20(campaign.tokenAddress);

        if (token.balanceOf(address(this)) < amountToReturn) {
            revert ContractBalanceInsufficient(
                amountToReturn,
                token.balanceOf(address(this))
            );
        }

        campaign.campaignStatus = CampaignStatus.DISCARDED;

        bool success = token.transfer(
            campaign.creatorAddress,
            campaign.amountOffered
        );
        if (!success) {
            revert FundTransferError();
        }

        emit CampaignUpdated(campaignId, msg.sender);
    }

    // ------------------ CAMPAIGN FUNCTIONS ------------------
    function createNewCampaign(
        address selectedKol,
        uint256 offeringAmount,
        uint256 promotionEndsIn,
        uint256 offerEndsIn,
        address tokenAddress
    ) external {
        require(allowedTokens[tokenAddress], "Token not allowed");
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

        uint256 currentTime = block.timestamp;
        Campaign memory campaign = Campaign({
            id: id,
            createdAt: currentTime,
            creatorAddress: msg.sender,
            selectedKol: selectedKol,
            offerEndsIn: offerEndsIn,
            promotionEndsIn: promotionEndsIn,
            amountOffered: offeringAmount,
            tokenAddress: tokenAddress,
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
        uint256 offerEndsIn,
        uint256 newAmountOffered
    ) external nonReentrant {
        require(selectedKol != address(0), "Invalid KOL address");
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.campaignStatus != CampaignStatus.OPEN) {
            revert InvalidCampaignStatus(
                CampaignStatus.OPEN,
                campaign.campaignStatus
            );
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        uint oldAmount = campaign.amountOffered;

        campaign.selectedKol = selectedKol;
        campaign.promotionEndsIn = promotionEndsIn;
        campaign.offerEndsIn = offerEndsIn;
        campaign.amountOffered = newAmountOffered;

        IERC20 token = IERC20(campaign.tokenAddress);

        if (oldAmount > newAmountOffered) {
            // return the extra
            bool success = token.transfer(
                campaign.creatorAddress,
                oldAmount - newAmountOffered
            );
            if (!success) {
                revert FundTransferError();
            }
        }

        emit CampaignUpdated(campaignId, msg.sender);
    }

    function acceptProjectCampaign(bytes4 campaignId) external nonReentrant {
        Campaign storage campaign = campaignInfo[campaignId];

        if (campaign.selectedKol != msg.sender && owner() != msg.sender) {
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

    function fulfilProjectCampaign(bytes4 campaignId) external nonReentrant {
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

        IERC20 token = IERC20(campaign.tokenAddress);

        if (token.balanceOf(address(this)) < amountToPayKol) {
            revert ContractBalanceInsufficient(
                amountToPayKol,
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

        emit CampaignFulfilled(campaignId);
    }

    // ------------------ OPEN CAMPAIGN FUNCTIONS ------------------
    function createOpenCampaign(
        uint256 promotionEndsIn,
        uint256 poolAmount,
        address tokenAddress
    ) external nonReentrant {
        require(allowedTokens[tokenAddress], "Token not allowed");
        bytes4 id = bytes4(
            bytes32(
                keccak256(
                    abi.encodePacked(
                        msg.sender,
                        "CREATE_OPEN_CAMPAIGN",
                        block.timestamp
                    )
                )
            )
        );

        OpenCampaign memory campaign = OpenCampaign({
            id: id,
            creatorAddress: msg.sender,
            promotionEndsIn: promotionEndsIn,
            poolAmount: poolAmount,
            campaignStatus: OpenCampaignStatus.PUBLISHED,
            tokenAddress: tokenAddress
        });

        openCampaignInfo[id] = campaign;
        allOpenCampaigns.push(id);
        userOpenCampaigns[msg.sender].push(id);

        // Transfer pool amount to contract externally handled by the frontend

        emit OpenCampaignCreated(id, msg.sender, poolAmount);
    }

    function completeOpenCampaign(
        bytes4 campaignId,
        bool isFulfilled
    ) external onlyOwner nonReentrant {
        OpenCampaign storage campaign = openCampaignInfo[campaignId];

        if (campaign.campaignStatus != OpenCampaignStatus.PUBLISHED) {
            revert InvalidOpenCampaignStatus(
                OpenCampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        campaign.campaignStatus = isFulfilled
            ? OpenCampaignStatus.FULFILLED
            : OpenCampaignStatus.DISCARDED;

        // Transfer pool amount to owner for manual distribution
        IERC20 token = IERC20(campaign.tokenAddress);
        bool success = token.transfer(owner(), campaign.poolAmount);
        if (!success) {
            revert FundTransferError();
        }

        emit OpenCampaignCompleted(campaignId, msg.sender, isFulfilled);
    }

    function updateOpenCampaign(
        bytes4 campaignId,
        uint256 promotionEndsIn,
        uint256 poolAmount,
        OpenCampaignStatus newStatus
    ) external nonReentrant {
        OpenCampaign storage campaign = openCampaignInfo[campaignId];

        // Only allow updates if campaign is PUBLISHED
        if (campaign.campaignStatus != OpenCampaignStatus.PUBLISHED) {
            revert InvalidOpenCampaignStatus(
                OpenCampaignStatus.PUBLISHED,
                campaign.campaignStatus
            );
        }

        // Only allow status updates to FULFILLED or DISCARDED
        if (
            newStatus != OpenCampaignStatus.FULFILLED &&
            newStatus != OpenCampaignStatus.DISCARDED
        ) {
            revert InvalidOpenCampaignStatus(
                OpenCampaignStatus.FULFILLED,
                newStatus
            );
        }

        if (campaign.creatorAddress != msg.sender && owner() != msg.sender) {
            revert Unauthorized();
        }

        uint256 oldAmount = campaign.poolAmount;

        campaign.promotionEndsIn = promotionEndsIn;
        campaign.poolAmount = poolAmount;
        campaign.campaignStatus = newStatus;

        IERC20 token = IERC20(campaign.tokenAddress);

        if (oldAmount > poolAmount) {
            // return the extra
            bool success = token.transfer(
                campaign.creatorAddress,
                oldAmount - poolAmount
            );
            if (!success) {
                revert FundTransferError();
            }
        }

        // If status is being updated to FULFILLED or DISCARDED, transfer funds to owner
        if (
            newStatus == OpenCampaignStatus.FULFILLED ||
            newStatus == OpenCampaignStatus.DISCARDED
        ) {
            bool success = token.transfer(owner(), poolAmount);
            if (!success) {
                revert FundTransferError();
            }
        }

        emit OpenCampaignUpdated(campaignId, msg.sender);
    }

    // ------------------ GETTERS ------------------

    function getAllCampaigns() external view returns (bytes4[] memory) {
        return allCampaigns;
    }

    function getUserCampaigns(
        address userAddress
    ) external view returns (bytes4[] memory) {
        return userCampaigns[userAddress];
    }

    function getCampaignInfo(
        bytes4 campaignId
    ) external view returns (Campaign memory) {
        Campaign memory campaign = campaignInfo[campaignId];
        return campaign;
    }

    function getAllOpenCampaigns() external view returns (bytes4[] memory) {
        return allOpenCampaigns;
    }

    function getUserOpenCampaigns(
        address userAddress
    ) external view returns (bytes4[] memory) {
        return userOpenCampaigns[userAddress];
    }

    function getOpenCampaignInfo(
        bytes4 campaignId
    ) external view returns (OpenCampaign memory) {
        OpenCampaign memory campaign = openCampaignInfo[campaignId];
        return campaign;
    }

    receive() external payable {}
}

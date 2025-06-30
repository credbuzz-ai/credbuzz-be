# CredBuzz Marketplace

A decentralized marketplace for influencer marketing campaigns built on Ethereum. The platform enables creators to create targeted campaigns for specific Key Opinion Leaders (KOLs) or open campaigns for public participation.

## 🏗️ Architecture Overview

The CredBuzz Marketplace consists of two main campaign types:

### 1. **Targeted Campaigns**

- Direct collaboration between creators and specific KOLs
- Pre-selected influencers for campaign execution
- Automated payment distribution with platform fees

### 2. **Public Campaigns (Open Campaigns)**

- Open pool campaigns for any eligible KOL
- Manual distribution by platform owner
- Flexible participation model

## 📋 Campaign Status Flow

Both campaign types follow the same unified status system:

```
PUBLISHED → FULFILLED/DISCARDED
```

- **PUBLISHED**: Campaign is active and available for fulfillment
- **FULFILLED**: Campaign has been successfully completed
- **DISCARDED**: Campaign has been cancelled and funds returned

## 🔄 Campaign Lifecycle

### Targeted Campaign Flow

1. **Campaign Creation**

   - Creator specifies KOL, amount, deadline, and token
   - Tokens are transferred to contract via `transferFrom`
   - Campaign status: `PUBLISHED`

2. **Campaign Fulfillment**

   - Selected KOL fulfills the campaign
   - Platform fees are deducted (10% by default)
   - Remaining amount is paid to KOL
   - Campaign status: `FULFILLED`

3. **Campaign Management**
   - Creator can update campaign details
   - Creator can discard campaign (funds returned)
   - Owner can pause/unpause contract

### Public Campaign Flow

1. **Campaign Creation**

   - Creator specifies pool amount, deadline, and token
   - Tokens are transferred to contract
   - Campaign status: `PUBLISHED`

2. **Campaign Completion**
   - Creator marks campaign as fulfilled or discarded
   - Funds are transferred to owner for manual distribution
   - Campaign status: `FULFILLED` or `DISCARDED`

## 🛠️ Setup & Installation

### Prerequisites

- Node.js (v16 or higher)
- npm or yarn
- Hardhat
- MetaMask or similar wallet

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd credbuzz-blockchain

# Install dependencies
npm install

# Or using yarn
yarn install
```

### Environment Configuration

Create a `.env` file in the root directory:

```env
PRIVATE_KEY=your_private_key_here
INFURA_URL=your_infura_url_here
ETHERSCAN_API_KEY=your_etherscan_api_key_here
```

### Compilation

```bash
# Compile contracts
npx hardhat compile

# Clean and recompile
npx hardhat clean
npx hardhat compile
```

## 🚀 Deployment

### Local Development

```bash
# Start local blockchain
npx hardhat node

# Deploy to local network
npx hardhat run scripts/deploy.js --network localhost
```

### Testnet Deployment

```bash
# Deploy to Sepolia testnet
npx hardhat run scripts/deploy.js --network sepolia

# Deploy to Base testnet
npx hardhat run scripts/deploy.js --network base-sepolia
```

### Mainnet Deployment

```bash
# Deploy to Ethereum mainnet
npx hardhat run scripts/deploy.js --network mainnet

# Deploy to Base mainnet
npx hardhat run scripts/deploy.js --network base
```

## 📝 Usage Examples

### Creating a Targeted Campaign

```javascript
const { ethers } = require("hardhat");

async function createTargetedCampaign() {
  const marketplace = await ethers.getContract("Marketplace");
  const token = await ethers.getContract("MockERC20");

  // Approve tokens first
  const amount = ethers.parseEther("1000");
  await token.approve(marketplace.address, amount);

  // Create campaign
  const selectedKol = "0x1234567890123456789012345678901234567890";
  const offeringAmount = ethers.parseEther("1000");
  const offerEndsIn = Math.floor(Date.now() / 1000) + 86400; // 24 hours
  const tokenAddress = token.address;

  const tx = await marketplace.createTargetedCampaign(
    selectedKol,
    offeringAmount,
    offerEndsIn,
    tokenAddress
  );

  await tx.wait();
  console.log("Targeted campaign created!");
}
```

### Creating a Public Campaign

```javascript
async function createPublicCampaign() {
  const marketplace = await ethers.getContract("Marketplace");
  const token = await ethers.getContract("MockERC20");

  // Approve tokens
  const poolAmount = ethers.parseEther("5000");
  await token.approve(marketplace.address, poolAmount);

  // Create open campaign
  const offerEndsIn = Math.floor(Date.now() / 1000) + 604800; // 7 days
  const tokenAddress = token.address;

  const tx = await marketplace.createPublicCampaign(
    offerEndsIn,
    poolAmount,
    tokenAddress
  );

  await tx.wait();
  console.log("Public campaign created!");
}
```

### Fulfilling a Targeted Campaign

```javascript
async function fulfillTargetedCampaign(campaignId) {
  const marketplace = await ethers.getContract("Marketplace");

  // Only selected KOL or owner can fulfill
  const tx = await marketplace.fulfilTargetedCampaign(campaignId);
  await tx.wait();

  console.log("Targeted campaign fulfilled!");
}
```

### Completing a Public Campaign

```javascript
async function completePublicCampaign(campaignId, isFulfilled) {
  const marketplace = await ethers.getContract("Marketplace");

  // Creator or owner can complete
  const tx = await marketplace.completePublicCampaign(campaignId, isFulfilled);
  await tx.wait();

  console.log("Public campaign completed!");
}
```

### Discarding a Public Campaign

```javascript
async function discardPublicCampaign(campaignId) {
  const marketplace = await ethers.getContract("Marketplace");

  // Creator or owner can discard
  const tx = await marketplace.discardPublicCampaign(campaignId);
  await tx.wait();

  console.log("Public campaign discarded!");
}
```

### Updating Campaign Details

```javascript
async function updateTargetedCampaign(campaignId) {
  const marketplace = await ethers.getContract("Marketplace");
  const token = await ethers.getContract("MockERC20");

  const newKol = "0x0987654321098765432109876543210987654321";
  const newAmount = ethers.parseEther("1200");
  const newDeadline = Math.floor(Date.now() / 1000) + 172800; // 48 hours

  // If increasing amount, approve additional tokens
  if (newAmount > oldAmount) {
    const additional = newAmount - oldAmount;
    await token.approve(marketplace.address, additional);
  }

  const tx = await marketplace.updateTargetedCampaign(
    campaignId,
    newKol,
    newDeadline,
    newAmount
  );

  await tx.wait();
  console.log("Targeted campaign updated!");
}
```

### Discarding a Campaign

```javascript
async function discardTargetedCampaign(campaignId) {
  const marketplace = await ethers.getContract("Marketplace");

  // Creator or owner can discard
  const tx = await marketplace.discardTargetedCampaign(campaignId);
  await tx.wait();

  console.log("Targeted campaign discarded!");
}
```

## 🧪 Testing

### Run All Tests

```bash
# Run all tests
npx hardhat test

# Run with gas reporting
REPORT_GAS=true npx hardhat test

# Run specific test file
npx hardhat test test/Marketplace.test.js
```

### Test Coverage

```bash
# Generate coverage report
npx hardhat coverage
```

### Test Examples

```javascript
describe("Marketplace", function () {
  it("Should create a targeted campaign", async function () {
    const [creator, kol] = await ethers.getSigners();
    const marketplace = await ethers.deployContract("Marketplace");
    const token = await ethers.deployContract("MockERC20");

    // Approve tokens
    await token.approve(marketplace.address, ethers.parseEther("1000"));

    // Create campaign
    await marketplace.createTargetedCampaign(
      kol.address,
      ethers.parseEther("1000"),
      Math.floor(Date.now() / 1000) + 86400,
      token.address
    );

    // Verify campaign creation
    const campaigns = await marketplace.getAllTargetedCampaigns();
    expect(campaigns.length).to.equal(1);
  });
});
```

## 🔧 Contract Functions

### Core Functions

| Function                    | Description               | Access        |
| --------------------------- | ------------------------- | ------------- |
| `createTargetedCampaign()`  | Create targeted campaign  | Public        |
| `createPublicCampaign()`    | Create public campaign    | Public        |
| `fulfilTargetedCampaign()`  | Fulfill targeted campaign | KOL/Owner     |
| `completePublicCampaign()`  | Complete public campaign  | Creator/Owner |
| `updateTargetedCampaign()`  | Update targeted campaign  | Creator/Owner |
| `discardTargetedCampaign()` | Discard targeted campaign | Creator/Owner |
| `discardPublicCampaign()`   | Discard public campaign   | Creator/Owner |

### Owner Functions

| Function               | Description                    |
| ---------------------- | ------------------------------ |
| `pause()`              | Pause contract operations      |
| `unpause()`            | Resume contract operations     |
| `withdrawToken()`      | Withdraw ERC20 tokens          |
| `withdrawEth()`        | Withdraw ETH                   |
| `updatePlatformFees()` | Update platform fee percentage |

### View Functions

| Function                          | Description                        |
| --------------------------------- | ---------------------------------- |
| `getAllTargetedCampaigns()`       | Get all targeted campaigns         |
| `getAllPublicCampaigns()`         | Get all public campaigns           |
| `getTargetedCampaignsPaginated()` | Get paginated targeted campaigns   |
| `getPublicCampaignsPaginated()`   | Get paginated public campaigns     |
| `getUserTargetedCampaigns()`      | Get user's targeted campaigns      |
| `getUserPublicCampaigns()`        | Get user's public campaigns        |
| `getTargetedCampaignInfo()`       | Get targeted campaign details      |
| `getPublicCampaignInfo()`         | Get public campaign details        |
| `targetedCampaignExists()`        | Check if targeted campaign exists  |
| `publicCampaignExists()`          | Check if public campaign exists    |
| `isTargetedCampaignExpired()`     | Check if targeted campaign expired |
| `isPublicCampaignExpired()`       | Check if public campaign expired   |

## 🔒 Security Features

- **Reentrancy Protection**: All critical functions use `nonReentrant` modifier
- **Pausable**: Emergency pause functionality for security incidents
- **Input Validation**: Comprehensive parameter validation
- **Authorization**: Proper access control for all functions
- **Balance Checks**: Verification before token transfers
- **Deadline Enforcement**: Campaign expiration handling

## 📊 Platform Fees

- **Default Fee**: 10% (10,000 basis points)
- **Configurable**: Owner can update fee percentage
- **Maximum Fee**: Cannot exceed 100,000 basis points
- **Distribution**: Fees go to contract owner

## 🌐 Supported Networks

- **Ethereum Mainnet**
- **Base Mainnet**
- **Sepolia Testnet**
- **Base Sepolia Testnet**
- **Local Development**

## 🚨 Emergency Procedures

### Pausing the Contract

```javascript
// Only owner can pause
await marketplace.pause();
```

### Unpausing the Contract

```javascript
// Only owner can unpause
await marketplace.unpause();
```

### Emergency Withdrawal

```javascript
// Withdraw all tokens
await marketplace.withdrawToken(tokenAddress);

// Withdraw all ETH
await marketplace.withdrawEth();
```

## 📞 Support & Contributing

### Getting Help

- Create an issue for bugs or feature requests
- Check existing issues for solutions
- Review the test files for usage examples

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

### Code Style

- Follow Solidity style guide
- Use meaningful variable names
- Add comprehensive comments
- Include error handling
- Write unit tests for all functions

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

**Note**: This is a production-ready smart contract. Always test thoroughly on testnets before deploying to mainnet. Ensure proper security audits are conducted before production use.

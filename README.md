# ArgoPump - Token Launch & DEX Platform on Aptos

ArgoPump is a comprehensive DeFi platform on Aptos that combines token creation, bonding curve mechanics, automated market making (AMM), and advanced liquidity management features.

## 🚀 Core Features

### 1. Token Factory
Create and manage fungible assets (FA) with integrated bonding curve mechanism.

#### Features:
- **Token Creation**: Create custom fungible assets with configurable metadata (name, symbol, icon URI, project URI)
- **Fixed Supply Model**: 
  - 800 million tokens allocated to bonding curve pool
  - 200 million tokens reserved for liquidity pool
  - 8 decimal places by default
- **Admin Management System**:
  - Two-step admin transfer (set pending admin → accept admin)
  - Admin can update mint fee collector
  - Supports deployment to objects or accounts
- **Resource Account Architecture**: Uses separate resource accounts for secure FA object creation
- **Creator Initial Buy**: Creators can optionally buy tokens during creation

#### Entry Functions:
- `create_fa()` - Create a new fungible asset
- `set_pending_admin()` - Set pending admin address
- `accept_admin()` - Accept admin role
- `update_mint_fee_collector()` - Update fee collector address

#### View Functions:
- `get_registry()` - Get all created tokens
- `get_mint_fee()` - Calculate mint fee for amount
- `get_admin()` - Get current admin
- `get_balance_of_user_by_fa_object_address()` - Get user balance
- `get_fa_object_metadata()` - Get token metadata

---

### 2. Bonding Curve Pool
Automated token trading using bonding curve mechanism with graduation to full DEX.

#### Features:
- **Bonding Curve Trading**:
  - x*y=k constant product formula with virtual reserves
  - Virtual APT reserves: 28.24 APT for price stability
  - Buy and sell tokens directly from the curve
- **Fee System**: 
  - 0.1% trading fee (100 basis points)
  - Fees sent to treasury
- **Graduation Mechanism**:
  - Automatic graduation at 21,500 APT threshold
  - Creates liquidity pool on graduation
  - Transfers remaining tokens and APT to LP
- **Pool State Management**: Tracks APT reserves and graduation status per token

#### Entry Functions:
- `buy_tokens()` - Buy tokens from bonding curve
- `sell_tokens()` - Sell tokens back to bonding curve

#### View Functions:
- `get_token_balance()` - Get token balance for account
- `get_apt_reserves()` - Get APT reserves in pool

#### Events:
- `TokenPurchaseEvent` - Emitted on token purchase
- `TokenSaleEvent` - Emitted on token sale
- `PoolGraduationEvent` - Emitted when pool graduates

---

### 3. Graduation Handler
Manages token graduation from bonding curve to liquidity pools.

#### Features:
- **Automatic LP Creation**: Creates liquidity pool when bonding curve graduates
- **Resource Account Management**: Uses dedicated resource account for pool creation
- **APT/FA Pair Creation**: Creates pools with APT as base asset
- **Initial Liquidity**: 
  - Deposits graduated APT reserves
  - Deposits 200M reserved tokens
  - 0.30% LP fee (30 basis points)
- **Named Pool Objects**: Deterministic pool addresses based on assets and fee

#### Entry Functions:
- `initialize()` - Initialize graduation pool manager (called once)

#### View Functions:
- `get_pool_address()` - Get expected pool address for FA object

#### Events:
- `GraduatedPoolCreatedEvent` - Emitted when graduated pool is created

---

### 4. Basic AMM (Liquidity Pools) (TAPP Exchange Integration)
Simple constant product AMM for token swaps and liquidity provision.

#### Features:
- **x*y=k Formula**: Classic constant product market maker
- **Two-Asset Pools**: Support for token pair trading
- **Position-Based Liquidity**:
  - Mint LP shares as positions
  - Proportional liquidity addition
  - Position-based removal
- **Swap Functionality**:
  - Bidirectional swaps (A→B and B→A)
  - Configurable slippage protection
  - Fee integration
- **Fee Configuration**: Customizable fee in basis points (1 bps = 0.01%)

#### Core Functions:
- `create_pool()` - Create new AMM pool
- `add_liquidity()` - Add liquidity to pool
- `remove_liquidity()` - Remove liquidity from pool
- `swap()` - Execute token swap

#### Pool Constraints:
- Exactly 2 assets required
- Assets must be different
- Fee must be > 0 and < 100%
- Slippage protection enforced

#### Events:
- `Created` - Pool creation
- `Added` - Liquidity addition
- `Removed` - Liquidity removal
- `Swapped` - Swap execution

---

### 5. Router & Hook System (TAPP Exchange Integration)
Unified entry point for all DEX operations with extensible hook architecture.

#### Features:
- **Unified Interface**: Single entry point for all pool operations
- **Pool Registry**: Tracks all created pools
- **Position NFT Management**:
  - NFT-based position tracking
  - Minting/burning on liquidity add/remove
  - Position authorization
- **Vault Integration**: Manages asset custody and transfers
- **Multi-Hook Support**:
  - Basic AMM hook
  - Advanced AMM with incentives
  - Vault hook (time-locked/insurance)
  - Extensible for custom hooks

#### Entry Functions:
- `create_pool()` - Create pool with specific hook type
- `create_pool_add_liquidity()` - Create pool and add liquidity atomically
- `add_liquidity()` - Add liquidity to existing pool
- `remove_liquidity()` - Remove liquidity from pool
- `swap()` - Execute swap
- `collect_fee()` - Collect accumulated fees

#### Events:
- `PoolCreated` - Pool creation with hook type
- `LiquidityAdded` - Liquidity addition
- `LiquidityRemoved` - Liquidity removal
- `Swapped` - Swap execution
- `FeeCollected` - Fee collection

---

### 6. Position NFTs (TAPP Exchange Integration)
NFT-based liquidity position tracking system.

#### Features:
- **NFT Collection**: "TAPP" collection for all positions
- **Position Metadata**:
  - Hook type (basic, advanced, vault)
  - Pool address
  - Position index
- **Ownership Transfer**: Standard NFT transfer mechanics
- **Position Burning**: Automatic burn on full liquidity removal
- **Authorization**: Position-based access control

#### Functions:
- `mint_position()` - Mint new position NFT
- `burn_position()` - Burn position NFT
- `authorized_borrow()` - Get position metadata with authorization
- `position_meta()` - Get position metadata

---

### 7. Vault System (TAPP Exchange Integration) (NOT IMPLEMENTED)
Time-locked and insurance vault implementations.

#### Features:
- **Time-Locked Vault**:
  - Lock assets for specified duration
  - Withdrawal only after lock expires
  - Fee on withdrawal
- **Insurance Vault**:
  - Flexible deposit/withdrawal
  - Fee mechanism
  - No time restrictions
- **Multi-Asset Support**: Support for multiple assets per vault
- **Slot-Based System**: Individual slots for each deposit
- **Fee Collection**: Configurable withdrawal fees

#### Vault Types:
1. **Time-Locked Vault (Type 1)**:
   - Lock duration specified at deposit
   - `lock_until` timestamp enforced
   - Early withdrawal prevented

2. **Insurance Vault (Type 2)**:
   - No time restrictions
   - Instant withdrawal available
   - Fee still applies

#### Functions:
- `create_pool()` - Create vault instance
- `deposit()` - Deposit to vault slot
- `withdraw()` - Withdraw from vault slot (redeem)
- `collect_fee()` - Collect accumulated fees

---

### 8. Advanced AMM (TAPP Exchange Integration) (NOT IMPLEMENTED)
Extended AMM with campaign-based incentive system.

#### Features:
- **Campaign System**: 
  - Multiple incentive campaigns per pool
  - Token-based rewards
  - Time-based distribution
  - Per-position reward tracking
- **Position Management**:
  - Multi-asset positions
  - Fee accumulation per position
  - Reward accumulation
- **Custom Pool Operations**: Extensible operation system
- **Fee Collection**: Per-position fee collection

#### Functions:
- `create_pool()` - Create advanced AMM pool
- `add_liquidity()` - Add liquidity with reward tracking
- `remove_liquidity()` - Remove liquidity and claim rewards
- `swap()` - Execute swap
- `collect_fee()` - Collect position fees
- `run_pool_op()` - Execute custom pool operations

---

### 9. Hook Factory (TAPP Exchange Integration)
Abstraction layer for multiple pool implementations.

#### Features:
- **Hook Types**:
  - `HOOK_BASIC (1)` - Basic x*y=k AMM
  - `HOOK_ADVANCED (2)` - AMM with incentives
  - `HOOK_VAULT (3)` - Vault systems
  - `YOUR_HOOK (4)` - Custom extensible hook
- **Unified Transaction Model**: 
  - Standard Tx struct for all operations
  - Asset tracking
  - In/out direction
  - Incentive flag
- **Reserve Management**:
  - Pool reserves tracking
  - Incentive reserves tracking
  - Automatic updates
- **Asset Validation**: Automatic asset sorting and validation

#### Functions:
- `create_pool()` - Route pool creation to appropriate hook
- `add_liquidity()` - Route liquidity addition
- `remove_liquidity()` - Route liquidity removal
- `swap()` - Route swap execution
- `collect_fee()` - Route fee collection
- `update_reserve()` - Update pool reserves
- `update_incentive_reserve()` - Update incentive reserves

---

## 📊 Token Economics

### Bonding Curve Parameters:
- **Initial Supply**: 1 billion tokens (1,000,000,000)
- **Bonding Curve Allocation**: 800 million (80%)
- **LP Reserve**: 200 million (20%)
- **Virtual APT Reserves**: 28.24 APT
- **Trading Fee**: 0.1% (100 basis points)
- **Graduation Threshold**: 21,500 APT
- **LP Fee (Post-Graduation)**: 0.30% (30 basis points)

### Flow:
1. **Token Creation**: Creator launches token with 1B supply
2. **Initial Trading**: Users buy/sell on bonding curve
3. **Fee Collection**: 0.1% fees sent to treasury
4. **Graduation**: At 21,500 APT, pool graduates
5. **LP Creation**: Automatic LP with remaining tokens + APT
6. **DEX Trading**: Token trades on full AMM

---

## 🔧 Configuration

### Constants:
```move
// Token Factory
DEFAULT_DECIMALS: 8
INITIAL_BONDING_CURVE_SUPPLY: 800_000_000_00000000
RESERVED_FA_FOR_LIQUIDITY_POOL: 200_000_000_00000000

// Bonding Curve
VIRTUAL_APT_RESERVES: 28_24_00000000 (28.24 APT)
GRADUATION_THRESHOLD: 21_500_00000000 (21,500 APT)
FEE_BASIS_POINTS: 100 (0.1%)

// Graduation Handler
LP_FEE_BPS: 30 (0.30%)
```

---

## 🏗️ Architecture

### Module Structure:
```
ArgoPump/
├── token_factory       # FA creation & management
├── bonding_curve_pool  # Bonding curve trading
├── graduation_handler  # LP creation on graduation
├── basic              # Basic AMM implementation
├── advanced           # Advanced AMM with incentives
├── vault              # Time-locked/Insurance vaults
├── router             # Unified entry point
├── hook_factory       # Hook abstraction layer
└── position           # NFT position tracking
```

### Resource Accounts:
- **FA Creator Account**: Creates token objects
- **Graduation Pool Account**: Creates graduated LP pools
- **Vault Account**: Manages pool custody

---

## 🔐 Security Features

- **Admin Controls**: Two-step admin transfer process
- **Slippage Protection**: Minimum output amount checks
- **Resource Account Isolation**: Separate accounts for different operations
- **Position Authorization**: NFT-based access control
- **Time Locks**: Enforced withdrawal restrictions
- **Reserve Validation**: Insufficient balance checks
- **Asset Validation**: Automatic sorting and duplicate prevention

---

## 📈 Events & Monitoring

### Token Factory Events:
- `CreateFAEvent` - Token creation
- `MintFAEvent` - Token minting
- `BurnFAEvent` - Token burning

### Bonding Curve Events:
- `TokenPurchaseEvent` - Purchase tracking
- `TokenSaleEvent` - Sale tracking
- `PoolGraduationEvent` - Graduation notification

### Router Events:
- `PoolCreated` - Pool creation
- `LiquidityAdded` - Liquidity events
- `LiquidityRemoved` - Liquidity removal
- `Swapped` - Swap execution
- `FeeCollected` - Fee collection

### AMM Events:
- `Created` - Pool creation
- `Added` - Liquidity addition
- `Removed` - Liquidity removal
- `Swapped` - Swap execution

---

## 🧪 Testing

The codebase includes comprehensive unit tests for:
- Token creation and management
- Bonding curve buy/sell mechanics
- AMM pool operations
- Liquidity provision/removal
- Swap functionality
- Slippage protection
- Fee calculations
- Position management

---

## 📝 Usage Examples

### Creating a Token:
```move
// Create token with optional initial buy
token_factory::create_fa(
    sender,
    name,           // "My Token"
    symbol,         // "MTK"
    icon_uri,       // "https://..."
    project_uri,    // "https://..."
    amount_buy      // option::some(1_00000000) for 1 APT worth
);
```

### Trading on Bonding Curve:
```move
// Buy tokens
bonding_curve_pool::buy_tokens(buyer, fa_object_addr, 1_00000000); // 1 APT

// Sell tokens
bonding_curve_pool::sell_tokens(seller, fa_object_addr, token_amount);
```

### Adding Liquidity (Post-Graduation) Integrated with TAPP Exchange:
```move
// Via router
router::add_liquidity(sender, args);
// args encode: pool_addr, position_addr_opt, amounts
```

### Swapping:
```move
// Via router
router::swap(sender, args);
// args encode: pool_addr, a2b, amount_in, min_amount_out
```

---

## 🔗 Dependencies

- **AptosFramework**: Core Aptos functionality
- **AptosTokenObjects**: NFT standard implementation
- **TAPP Exchange Hooks**: DEX Interactions

---

## 📄 License

See Move.toml for package details and upgrade policy: `compatible`

---

## ⚠️ Disclaimer

This is a DeFi protocol. Users should:
- Understand bonding curve mechanics
- Be aware of impermanent loss in AMM
- Verify token authenticity
- Check graduation status before trading
- Review time-lock terms for vaults

---

**Built on Aptos Move**

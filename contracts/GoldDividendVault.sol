// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                            ERRORS
//////////////////////////////////////////////////////////////*/

error ZeroAddress();
error AlreadyInitialized();
error NotAdmin();
error NotAdminOrDistributor();
error NotAdminOrGuardian();
error OnlyVaultPortal();
error Reentrant();
error AmountZero();
error InvalidArrayLength();
error TooManyRecipients();
error DistributionsPaused();
error DistributionNotActive();
error TransferFailed();
error InsufficientBNB();
error InsufficientGoldBalance();
error NothingToWithdraw();
error CloneFailed();
error UnsupportedChain(uint256 chainId);
error NotEnoughTokens();
error SwapFailed();

/*//////////////////////////////////////////////////////////////
                        INTERFACES
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeRouter02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function WETH() external pure returns (address);
}

/*//////////////////////////////////////////////////////////////
                        FLAP UI SCHEMAS
//////////////////////////////////////////////////////////////*/

struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

struct VaultDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}

/*//////////////////////////////////////////////////////////////
                        FLAP BASE
//////////////////////////////////////////////////////////////*/

abstract contract VaultBaseV2 {
    function _getGuardian() internal view returns (address) {
        if (block.chainid == 56) {
            return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        }
        if (block.chainid == 97) {
            return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        }
        revert UnsupportedChain(block.chainid);
    }

    function _getRouter() internal view returns (address) {
        if (block.chainid == 56) {
            return 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2 mainnet
        }
        if (block.chainid == 97) {
            return 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3; // PancakeSwap V2 testnet
        }
        revert UnsupportedChain(block.chainid);
    }

    function description() public view virtual returns (string memory);
    function vaultUISchema() public pure virtual returns (VaultUISchema memory);
}

/*//////////////////////////////////////////////////////////////
            GOLD DIVIDEND VAULT — IMPLEMENTATION
//////////////////////////////////////////////////////////////*/

contract GoldDividendVaultImplementation is VaultBaseV2 {

    uint256 public constant MAX_RECIPIENTS_PER_TX = 200;

    // 100,000 tokens required to be eligible for gold distribution
    uint256 public constant MIN_TOKEN_BALANCE = 100_000 ether;

    // Fee split: 85% goes to buy GOLD, 15% stays as treasury reserve
    uint256 public constant GOLD_BPS     = 8500;
    uint256 public constant TREASURY_BPS = 1500;
    uint256 public constant BPS_BASE     = 10_000;

    // Tokenized GOLD on BSC
    address public constant GOLD_TOKEN = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    bool    public initialized;

    address public taxToken;    // $黄金分红金库 token — used to verify holder eligibility
    address public admin;       // owner: activates + executes distributions, admin controls
    address public treasury;    // receives emergency withdrawals
    address public distributor; // can trigger gold purchases (buyGold)

    bool public distributionActive;  // owner must activate before distributing
    bool public distributionsPaused; // guardian or admin can pause as kill-switch

    uint256 private locked;

    // ── Accounting ──────────────────────────────────────────────
    uint256 public totalBNBReceived;         // all BNB ever received
    uint256 public totalBNBConvertedToGold;  // BNB spent swapping for GOLD
    uint256 public goldFundBalance;          // BNB queued for GOLD purchase (85%)
    uint256 public treasuryBNBBalance;       // BNB in treasury reserve (15%)
    uint256 public totalGoldDistributed;     // GOLD tokens sent to holders (in wei)

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event BNBReceived(address indexed from, uint256 amount, uint256 goldFund, uint256 treasuryFund);
    event GoldPurchased(uint256 bnbSpent, uint256 goldReceived);
    event DistributionActiveSet(bool active);
    event GoldDistributed(uint256 totalGoldAmount, uint256 recipientCount);
    event GoldSent(address indexed recipient, uint256 amount);
    event EmergencyWithdrawAll(address indexed to, uint256 bnbAmount, uint256 goldAmount);
    event DistributionsPausedSet(bool paused);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event DistributorChanged(address indexed oldDistributor, address indexed newDistributor);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    // Lock implementation so it cannot be initialized directly
    constructor() {
        initialized = true;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _taxToken,
        address _admin,
        address _treasury,
        address _distributor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (_taxToken  == address(0)) revert ZeroAddress();
        if (_admin     == address(0)) revert ZeroAddress();
        if (_treasury  == address(0)) revert ZeroAddress();

        initialized = true;
        locked      = 1;

        taxToken    = _taxToken;
        admin       = _admin;
        treasury    = _treasury;
        distributor = _distributor == address(0) ? _admin : _distributor;
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrDistributor() {
        if (msg.sender != admin && msg.sender != distributor) revert NotAdminOrDistributor();
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && msg.sender != _getGuardian()) revert NotAdminOrGuardian();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE BNB — AUTO SPLIT
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        if (msg.value == 0) return;
        _splitFees(msg.value);
    }

    function fundVault() external payable {
        if (msg.value == 0) revert AmountZero();
        _splitFees(msg.value);
    }

    function _splitFees(uint256 amount) internal {
        totalBNBReceived += amount;
        uint256 goldPart     = (amount * GOLD_BPS) / BPS_BASE;
        uint256 treasuryPart = amount - goldPart; // remainder avoids dust
        goldFundBalance    += goldPart;
        treasuryBNBBalance += treasuryPart;
        emit BNBReceived(msg.sender, amount, goldPart, treasuryPart);
    }

    /*//////////////////////////////////////////////////////////////
                        BUY GOLD (ADMIN / DISTRIBUTOR)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swaps `amountBNB` from the gold fund into tokenized GOLD via PancakeSwap.
     * @param amountBNB   BNB to spend (must be <= goldFundBalance).
     * @param minGoldOut  Minimum GOLD tokens to receive (slippage protection).
     * @param deadline    Unix timestamp deadline for the swap.
     */
    function buyGold(
        uint256 amountBNB,
        uint256 minGoldOut,
        uint256 deadline
    ) external onlyAdminOrDistributor nonReentrant {
        if (amountBNB == 0) revert AmountZero();
        if (amountBNB > goldFundBalance) revert InsufficientBNB();

        goldFundBalance         -= amountBNB;
        totalBNBConvertedToGold += amountBNB;

        address router = _getRouter();
        address[] memory path = new address[](2);
        path[0] = IPancakeRouter02(router).WETH();
        path[1] = GOLD_TOKEN;

        uint256 goldBefore = IERC20(GOLD_TOKEN).balanceOf(address(this));

        try IPancakeRouter02(router).swapExactETHForTokens{value: amountBNB}(
            minGoldOut,
            path,
            address(this),
            deadline
        ) returns (uint256[] memory) {
            uint256 goldReceived = IERC20(GOLD_TOKEN).balanceOf(address(this)) - goldBefore;
            emit GoldPurchased(amountBNB, goldReceived);
        } catch {
            // Refund on swap failure
            goldFundBalance         += amountBNB;
            totalBNBConvertedToGold -= amountBNB;
            revert SwapFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DISTRIBUTION — OWNER ONLY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Owner activates or deactivates gold distribution.
     *         Distribution functions revert unless this is set to true.
     */
    function setDistributionActive(bool active) external onlyAdmin {
        distributionActive = active;
        emit DistributionActiveSet(active);
    }

    /**
     * @notice Distributes GOLD to eligible holders.
     *         Only callable by owner, only when distributionActive == true.
     *         Amounts are computed off-chain proportional to each holder's
     *         share of the total eligible supply.
     *         Each recipient must hold >= 100,000 $黄金分红金库 tokens.
     *
     * @param recipients  Wallet addresses to receive GOLD.
     * @param amounts     GOLD amount (in wei) for each recipient.
     */
    function distributeGold(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyAdmin nonReentrant {
        if (!distributionActive)  revert DistributionNotActive();
        if (distributionsPaused)  revert DistributionsPaused();

        uint256 len = recipients.length;
        if (len == 0)                    revert AmountZero();
        if (len != amounts.length)       revert InvalidArrayLength();
        if (len > MAX_RECIPIENTS_PER_TX) revert TooManyRecipients();

        // Validate recipients and sum total
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < len; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0)             revert AmountZero();
            if (IERC20(taxToken).balanceOf(recipients[i]) < MIN_TOKEN_BALANCE)
                revert NotEnoughTokens();
            totalAmount += amounts[i];
        }

        if (IERC20(GOLD_TOKEN).balanceOf(address(this)) < totalAmount)
            revert InsufficientGoldBalance();

        totalGoldDistributed += totalAmount;
        emit GoldDistributed(totalAmount, len);

        for (uint256 i = 0; i < len; i++) {
            bool ok = IERC20(GOLD_TOKEN).transfer(recipients[i], amounts[i]);
            if (!ok) revert TransferFailed();
            emit GoldSent(recipients[i], amounts[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAW — ADMIN ONLY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraws ALL BNB (gold fund + treasury reserve) and ALL GOLD tokens
     *         to the treasury address. Pauses and deactivates distributions.
     *         Use only in emergencies.
     */
    function emergencyWithdrawAll() external onlyAdmin nonReentrant {
        distributionsPaused = true;
        distributionActive  = false;

        uint256 bnbAmount  = address(this).balance;
        uint256 goldAmount = IERC20(GOLD_TOKEN).balanceOf(address(this));

        // Reset internal accounting
        goldFundBalance    = 0;
        treasuryBNBBalance = 0;

        if (bnbAmount > 0) {
            (bool ok, ) = payable(treasury).call{value: bnbAmount}("");
            if (!ok) revert TransferFailed();
        }

        if (goldAmount > 0) {
            bool ok = IERC20(GOLD_TOKEN).transfer(treasury, goldAmount);
            if (!ok) revert TransferFailed();
        }

        emit DistributionsPausedSet(true);
        emit DistributionActiveSet(false);
        emit EmergencyWithdrawAll(treasury, bnbAmount, goldAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function goldBalance() public view returns (uint256) {
        return IERC20(GOLD_TOKEN).balanceOf(address(this));
    }

    /**
     * @notice Returns the key vault metrics for the Flap UI dashboard.
     */
    function getVaultStats() external view returns (
        uint256 _totalBNBReceived,
        uint256 _totalBNBConvertedToGold,
        uint256 _goldFundBalance,
        uint256 _treasuryBNBBalance,
        uint256 _currentGoldBalance,
        uint256 _totalGoldDistributed,
        bool    _distributionActive,
        bool    _distributionsPaused
    ) {
        return (
            totalBNBReceived,
            totalBNBConvertedToGold,
            goldFundBalance,
            treasuryBNBBalance,
            goldBalance(),
            totalGoldDistributed,
            distributionActive,
            distributionsPaused
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN CONTROLS
    //////////////////////////////////////////////////////////////*/

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address old = admin;
        admin = newAdmin;
        emit AdminChanged(old, newAdmin);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryChanged(old, newTreasury);
    }

    function setDistributor(address newDistributor) external onlyAdmin {
        if (newDistributor == address(0)) revert ZeroAddress();
        address old = distributor;
        distributor = newDistributor;
        emit DistributorChanged(old, newDistributor);
    }

    function setDistributionsPaused(bool paused) external onlyAdminOrGuardian {
        distributionsPaused = paused;
        emit DistributionsPausedSet(paused);
    }

    /*//////////////////////////////////////////////////////////////
                    FLAP UI SCHEMA
    //////////////////////////////////////////////////////////////*/

    function description() public pure override returns (string memory) {
        return unicode"黄金分红金库：FLAP手续费的85%自动买入链上代币化黄金，按持仓比例分红给持有100,000枚以上$黄金分红金库代币的持有者。15%存入金库储备。";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType   = unicode"黄金分红金库";
        schema.description = unicode"通过FLAP生成的手续费购买代币化黄金(GOLD)并分配给符合资格的持有者。85%手续费用于购买GOLD并分红，15%存入金库储备。持有100,000枚以上$黄金分红金库代币即可参与分红。";

        schema.methods = new VaultMethodSchema[](4);

        // ── getVaultStats ─────────────────────────────────────────
        schema.methods[0].name        = "getVaultStats";
        schema.methods[0].description = unicode"查看金库核心数据：累计手续费、已转换黄金的手续费、金库储备余额、当前GOLD余额及分红总量。";
        schema.methods[0].inputs      = new FieldDescriptor[](0);
        schema.methods[0].outputs     = new FieldDescriptor[](8);
        schema.methods[0].approvals   = new ApproveAction[](0);

        schema.methods[0].outputs[0] = FieldDescriptor("totalBNBReceived",        "uint256", unicode"累计收到手续费 (BNB)",    18);
        schema.methods[0].outputs[1] = FieldDescriptor("totalBNBConvertedToGold", "uint256", unicode"已兑换为GOLD的BNB",       18);
        schema.methods[0].outputs[2] = FieldDescriptor("goldFundBalance",         "uint256", unicode"待购买GOLD的BNB余额",     18);
        schema.methods[0].outputs[3] = FieldDescriptor("treasuryBNBBalance",      "uint256", unicode"金库储备BNB (15%)",       18);
        schema.methods[0].outputs[4] = FieldDescriptor("currentGoldBalance",      "uint256", unicode"当前GOLD代币余额",        18);
        schema.methods[0].outputs[5] = FieldDescriptor("totalGoldDistributed",    "uint256", unicode"累计已分红GOLD",          18);
        schema.methods[0].outputs[6] = FieldDescriptor("distributionActive",      "bool",    unicode"分红是否已激活",           0);
        schema.methods[0].outputs[7] = FieldDescriptor("distributionsPaused",     "bool",    unicode"是否已暂停",              0);

        schema.methods[0].isInputArray  = false;
        schema.methods[0].isOutputArray = false;
        schema.methods[0].isWriteMethod = false;

        // ── buyGold ───────────────────────────────────────────────
        schema.methods[1].name        = "buyGold";
        schema.methods[1].description = unicode"管理员将金库中的BNB通过PancakeSwap兑换为代币化GOLD。";
        schema.methods[1].inputs      = new FieldDescriptor[](3);
        schema.methods[1].outputs     = new FieldDescriptor[](0);
        schema.methods[1].approvals   = new ApproveAction[](0);

        schema.methods[1].inputs[0] = FieldDescriptor("amountBNB",  "uint256", unicode"用于购买GOLD的BNB数量",   18);
        schema.methods[1].inputs[1] = FieldDescriptor("minGoldOut", "uint256", unicode"最少获得GOLD数量（防滑点）", 18);
        schema.methods[1].inputs[2] = FieldDescriptor("deadline",   "uint256", unicode"交易截止时间戳",           0);

        schema.methods[1].isInputArray  = false;
        schema.methods[1].isOutputArray = false;
        schema.methods[1].isWriteMethod = true;

        // ── setDistributionActive ─────────────────────────────────
        schema.methods[2].name        = "setDistributionActive";
        schema.methods[2].description = unicode"Owner激活或关闭分红开关。只有激活后才能执行distributeGold。";
        schema.methods[2].inputs      = new FieldDescriptor[](1);
        schema.methods[2].outputs     = new FieldDescriptor[](0);
        schema.methods[2].approvals   = new ApproveAction[](0);

        schema.methods[2].inputs[0] = FieldDescriptor("active", "bool", unicode"true=激活  false=关闭", 0);

        schema.methods[2].isInputArray  = false;
        schema.methods[2].isOutputArray = false;
        schema.methods[2].isWriteMethod = true;

        // ── distributeGold ────────────────────────────────────────
        schema.methods[3].name        = "distributeGold";
        schema.methods[3].description = unicode"Owner将GOLD按持仓比例分发给持有100,000枚以上$黄金分红金库代币的持有者。需先激活分红开关。";
        schema.methods[3].inputs      = new FieldDescriptor[](2);
        schema.methods[3].outputs     = new FieldDescriptor[](0);
        schema.methods[3].approvals   = new ApproveAction[](0);

        schema.methods[3].inputs[0] = FieldDescriptor("recipients", "address[]", unicode"分红钱包地址列表", 0);
        schema.methods[3].inputs[1] = FieldDescriptor("amounts",    "uint256[]", unicode"对应GOLD分红数量（wei）", 18);

        schema.methods[3].isInputArray  = true;
        schema.methods[3].isOutputArray = false;
        schema.methods[3].isWriteMethod = true;
    }
}

/*//////////////////////////////////////////////////////////////
            GOLD DIVIDEND VAULT — FACTORY
//////////////////////////////////////////////////////////////*/

abstract contract VaultFactoryBaseV2 {
    function _getVaultPortal() internal view returns (address) {
        if (block.chainid == 56) {
            return 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        }
        if (block.chainid == 97) {
            return 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        }
        revert UnsupportedChain(block.chainid);
    }

    function newVault(
        address taxToken,
        address quoteToken,
        address creator,
        bytes calldata vaultData
    ) external virtual returns (address vault);

    function isQuoteTokenSupported(address quoteToken) public view virtual returns (bool);

    function vaultDataSchema() public pure virtual returns (VaultDataSchema memory schema);
}

contract GoldDividendVaultFactory is VaultFactoryBaseV2 {
    address public immutable implementation;

    event GoldDividendVaultCreated(
        address indexed taxToken,
        address indexed vault,
        address indexed creator,
        address treasury,
        address distributor
    );

    constructor(address _implementation) {
        if (_implementation == address(0)) revert ZeroAddress();
        implementation = _implementation;
    }

    /**
     * vaultData: abi.encode(treasury, distributor)
     *
     * - distributor can be address(0) — uses creator as distributor
     * - creator becomes the admin (owner) of the vault
     */
    function newVault(
        address taxToken,
        address,        // quoteToken — unused, only BNB supported
        address creator,
        bytes calldata vaultData
    ) external override returns (address vault) {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();

        (address treasury, address distributor) = abi.decode(vaultData, (address, address));

        if (taxToken  == address(0)) revert ZeroAddress();
        if (creator   == address(0)) revert ZeroAddress();
        if (treasury  == address(0)) revert ZeroAddress();

        vault = _clone(implementation);

        GoldDividendVaultImplementation(payable(vault)).initialize(
            taxToken,
            creator,
            treasury,
            distributor
        );

        emit GoldDividendVaultCreated(taxToken, vault, creator, treasury, distributor);
    }

    function isQuoteTokenSupported(address) public pure override returns (bool) {
        return true;
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"创建黄金分红金库。手续费的85%自动购买链上代币化黄金并按持仓比例分红，15%存入金库储备。持有100,000枚以上代币的钱包即可参与分红。";

        schema.fields = new FieldDescriptor[](2);

        schema.fields[0] = FieldDescriptor(
            "treasury",
            "address",
            unicode"金库钱包地址（紧急提款目标）",
            0
        );

        schema.fields[1] = FieldDescriptor(
            "distributor",
            "address",
            unicode"执行购买GOLD的钱包地址，填0则使用创建者",
            0
        );

        schema.isArray = false;
    }

    function _clone(address target) internal returns (address result) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            target,
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        assembly {
            result := create(0, add(code, 0x20), mload(code))
        }

        if (result == address(0)) revert CloneFailed();
    }
}

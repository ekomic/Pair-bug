/**
 * BankOfLinea Token (BOL)
 * 
 * Fee Structure:
 * - 10% fee on buy transactions
 * - 15% fee on sell transactions
 * - 2% fee on transfer transactions
 * 
 * Fee Distribution (All Transactions - Buy, Sell, Transfer):
 * - 70% of fees to USDC rewards for holders (7% on buy, 10.5% on sell, 1.4% on transfer)
 * - 18% of fees to marketing wallet (1.8% on buy, 2.7% on sell, 0.36% on transfer, sent as ETH)
 * - 10% of fees to development wallet (1% on buy, 1.5% on sell, 0.2% on transfer, sent as ETH)
 * - 2% of fees to liquidity (0.2% on buy, 0.3% on sell, 0.04% on transfer)
 * - 0% burn (no tokens are burned)
 * 
 * Rewards are distributed to holders in USDC via a dividend system, proportional to their BOL holdings.
 * Taxes are collected in BOL tokens, swapped for ETH, and distributed as specified.
 * Tax rates and receiver addresses can be adjusted by the contract owner.
 * Certain addresses (e.g., owner, contract, liquidity/marketing/development receivers) are exempt from taxes.
 * Features include:
 * - Anti-bot measures (high fees for flagged bot addresses)
 * - Transaction and wallet size limits
 * - Reentrancy protection for transfers and swaps
 * - Emergency token rescue for ERC20 tokens and USDC
 * - Slippage tolerance for liquidity addition
 * - Failed swap handling with retry mechanism
 * - Configurable router and USDC reward token addresses
 * - Pausable mechanism for emergency halts
 * - Transparent fee accumulation queries
 * Dividends are distributed automatically during transfers or can be claimed individually by holders.
 * Batch dividend distribution is deprecated; holders must claim dividends manually.
 * 
 * Links:
 * https://linktr.ee/bankoflinea
 * https://bankoflinea.build/
 * https://x.com/bankoflinea
 */

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IERC20Extended is IERC20 {
    function circulatingSupply() external view returns (uint256);
    function getOwner() external view returns (address);
}

abstract contract Ownable {
    address internal owner;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender), "!OWNER");
        _;
    }

    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    /// @notice Transfers ownership to a new address
    /// @param adr The new owner's address
    function transferOwnership(address payable adr) public onlyOwner {
        require(adr != address(0), "Owner cannot be zero address");
        owner = adr;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract BankOfLinea is IERC20Extended, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string private constant _name = "Bank of Linea";
    string private constant _symbol = "BOL";
    uint8 private constant _decimals = 18;
    uint256 private constant _totalSupply = 100_000_000 * (10 ** _decimals);
    uint256 private _maxTxAmount = (_totalSupply * 100) / 10_000; // 1%
    uint256 private _maxSellAmount = (_totalSupply * 200) / 10_000; // 2%
    uint256 private _maxWalletToken = (_totalSupply * 200) / 10_000; // 2%

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public isFeeExempt;
    mapping(address => bool) public isDividendExempt;
    mapping(address => bool) private isBot;

    IRouter public router;
    address public pair;
    bool private tradingAllowed = false;

    uint256 private liquidityFee = 200; // 2%
    uint256 private marketingFee = 1800; // 18%
    uint256 private rewardsFee = 7000; // 70%
    uint256 private developmentFee = 1000; // 10%
    uint256 private totalFee = 1000; // 10% for buys
    uint256 private sellFee = 1500; // 15% for sells
    uint256 private transferFee = 200; // 2% for transfers
    uint256 private constant denominator = 10_000;

    bool private swapEnabled = true;
    uint256 private swapTimes;
    bool private swapping;
    uint256 private swapThreshold = (_totalSupply * 100) / 100_000; // 0.1%
    uint256 private _minTokenAmount = (_totalSupply * 10) / 100_000;
    uint256 private queuedTokens; // Tracks tokens from failed swaps
    uint256 private lastRetryAttempt; // For timelock on retrySwap
    uint256 private constant RETRY_TIMELOCK = 1 days;

    modifier lockTheSwap {
        swapping = true;
        _;
        swapping = false;
    }
    modifier onlyAfterTimelock {
        require(block.timestamp >= lastRetryAttempt + RETRY_TIMELOCK, "Timelock active");
        _;
    }

    address public reward; // USDC
    uint8 private rewardDecimals; // USDC decimals (typically 6)
    uint128 public totalShares; // Reduced to uint128 for gas savings
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 internal dividendsPerShare;
    uint256 internal constant dividendsPerShareAccuracyFactor = 10**36;

    // Optimized shareholder tracking
    mapping(address => uint256) private shareholderClaims;
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }
    mapping(address => Share) public shares;
    mapping(address => bool) private isShareholder; // Tracks active shareholders

    uint256 public minPeriod = 60 minutes;
    uint256 public minDistribution = 1 * (10**16); // 0.01 USDC
    uint256 public distributorGas = 350_000;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public development_receiver;
    address public marketing_receiver;
    address public liquidity_receiver;
    uint256 public liquiditySlippageTolerance = 9500; // 95% (5% slippage)

    // Events
    event SwapEvent(address indexed token, uint256 amountIn, uint256 amountOut, bool success, string reason);
    event LiquidityAdded(uint256 tokenAmount, uint256 ethAmount, uint256 tokenMin, uint256 ethMin);
    event SlippageToleranceUpdated(uint256 newTolerance);
    event ReceiverAddressesUpdated(address developmentReceiver, address marketingReceiver, address liquidityReceiver);
    event RouterUpdated(address routerAddress);
    event RewardUpdated(address usdcAddress);
    event DividendsDistributed(address indexed shareholder, uint256 amount);
    event SwapRetryTriggered(uint256 amount);
    event DistributionProgress(uint256 processed);
    event ETHTransferred(address indexed receiver, uint256 amount);
    event ETHReceived(address indexed sender, uint256 amount);

    /// @notice Initializes the contract with router and USDC addresses
    /// @param routerAddress The address of the DEX router
    /// @param usdcAddress The address of the USDC token for dividends
    constructor(address routerAddress, address usdcAddress) Ownable(msg.sender) {
        require(routerAddress != address(0), "Router cannot be zero address");
        require(usdcAddress != address(0), "USDC cannot be zero address");

        IRouter _router = IRouter(routerAddress);
        address _pair = IFactory(_router.factory()).createPair(address(this), _router.WETH());
        router = _router;
        pair = _pair;
        reward = usdcAddress;
        rewardDecimals = IERC20Metadata(reward).decimals();
        require(rewardDecimals <= 18, "Invalid reward token decimals");

        development_receiver = 0x0F245A7D374388CD76fC8139Dd900E9B02bF69d7;
        marketing_receiver = 0x27DFbEC90EEa392446f71638b70193c6F558c001;
        liquidity_receiver = 0xd53686b4298Ac78B1d182E95FeAC1A4DD1D780bD;

        isFeeExempt[address(this)] = true;
        isFeeExempt[development_receiver] = true;
        isFeeExempt[liquidity_receiver] = true;
        isFeeExempt[marketing_receiver] = true;
        isFeeExempt[msg.sender] = true;
        isDividendExempt[address(pair)] = true;
        isDividendExempt[address(msg.sender)] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[address(DEAD)] = true;
        isDividendExempt[address(0)] = true;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    /// @notice Updates receiver addresses for fee distribution
    /// @param _developmentReceiver Address for development funds
    /// @param _marketingReceiver Address for marketing funds
    /// @param _liquidityReceiver Address for liquidity funds
    function setReceiverAddresses(
        address _developmentReceiver,
        address _marketingReceiver,
        address _liquidityReceiver
    ) external onlyOwner {
        require(_developmentReceiver != address(0), "Development receiver cannot be zero address");
        require(_marketingReceiver != address(0), "Marketing receiver cannot be zero address");
        require(_liquidityReceiver != address(0), "Liquidity receiver cannot be zero address");
        require(!isContract(_developmentReceiver), "Development receiver cannot be a contract");
        require(!isContract(_marketingReceiver), "Marketing receiver cannot be a contract");
        require(!isContract(_liquidityReceiver), "Liquidity receiver cannot be a contract");

        isFeeExempt[development_receiver] = false;
        isFeeExempt[marketing_receiver] = false;
        isFeeExempt[liquidity_receiver] = false;
        development_receiver = _developmentReceiver;
        marketing_receiver = _marketingReceiver;
        liquidity_receiver = _liquidityReceiver;
        isFeeExempt[development_receiver] = true;
        isFeeExempt[marketing_receiver] = true;
        isFeeExempt[liquidity_receiver] = true;
        emit ReceiverAddressesUpdated(_developmentReceiver, _marketingReceiver, _liquidityReceiver);
    }

    /// @notice Checks if an address is a contract
    /// @param addr The address to check
    /// @return True if the address is a contract
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /// @notice Sets the slippage tolerance for liquidity addition
    /// @param _tolerance Slippage tolerance (8500 = 85%, 9800 = 98%)
    function setLiquiditySlippageTolerance(uint256 _tolerance) external onlyOwner {
        require(_tolerance >= 8500 && _tolerance <= 9800, "Tolerance must be between 85% and 98%");
        liquiditySlippageTolerance = _tolerance;
        emit SlippageToleranceUpdated(_tolerance);
    }

    /// @notice Updates the router address and pair
    /// @param _routerAddress The new DEX router address
    function setRouter(address _routerAddress) external onlyOwner {
        require(_routerAddress != address(0), "Router cannot be zero address");
        router = IRouter(_routerAddress);
        pair = IFactory(router.factory()).getPair(address(this), router.WETH());
        if (pair == address(0)) {
            pair = IFactory(router.factory()).createPair(address(this), router.WETH());
        }
        emit RouterUpdated(_routerAddress);
    }

    /// @notice Updates the reward token (USDC) address
    /// @param _usdcAddress The new USDC token address
    function setReward(address _usdcAddress) external onlyOwner {
        require(_usdcAddress != address(0), "USDC cannot be zero address");
        uint8 usdcDecimals = IERC20Metadata(_usdcAddress).decimals();
        require(usdcDecimals >= 6 && usdcDecimals <= 18, "Reward token decimals must be 6 to 18");
        reward = _usdcAddress;
        rewardDecimals = usdcDecimals;
        emit RewardUpdated(_usdcAddress);
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    // ERC20 standard functions
    /// @notice Returns the token name
    /// @return The name of the token
    function name() public pure returns (string memory) {
        return _name;
    }

    /// @notice Returns the token symbol
    /// @return The symbol of the token
    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the token decimals
    /// @return The number of decimals
    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    /// @notice Returns the current owner
    /// @return The owner's address
    function getOwner() external view override returns (address) {
        return owner;
    }

    /// @notice Returns the total token supply
    /// @return The total supply
    function totalSupply() public pure override returns (uint256) {
        return _totalSupply;
    }

    /// @notice Returns the balance of an account
    /// @param account The account to query
    /// @return The token balance
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /// @notice Transfers tokens to a recipient
    /// @param recipient The recipient's address
    /// @param amount The amount to transfer
    /// @return True if successful
    function transfer(address recipient, uint256 amount) public override nonReentrant returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    /// @notice Returns the allowance for a spender
    /// @param owner_ The token owner's address
    /// @param spender The spender's address
    /// @return The allowed amount
    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    /// @notice Approves a spender to spend tokens
    /// @param spender The spender's address
    /// @param amount The amount to approve
    /// @return True if successful
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Returns the circulating supply (excluding burned tokens)
    /// @return The circulating supply
    function circulatingSupply() public view override returns (uint256) {
        return _totalSupply - balanceOf(DEAD) - balanceOf(address(0));
    }

    /// @notice Enables trading for the token
    function startTrading() external onlyOwner {
        require(!tradingAllowed, "Trading is already open");
        tradingAllowed = true;
    }

    /// @notice Validates transaction preconditions
    /// @param sender The sender's address
    /// @param amount The transfer amount
    function preTxCheck(address sender, uint256 amount) internal view {
        require(amount > 0, "Transfer amount must be greater than zero");
        require(amount <= balanceOf(sender), "Insufficient balance");
    }

    /// @notice Handles token transfers with fees and dividends
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    function _transfer(address sender, address recipient, uint256 amount) private {
        preTxCheck(sender, amount);
        checkTradingAllowed(sender, recipient);
        checkMaxWallet(sender, recipient, amount);
        swapbackCounters(sender, recipient);
        checkTxLimit(sender, recipient, amount);
        swapBack(sender, recipient, amount);
        _balances[sender] -= amount;
        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] += amountReceived;
        emit Transfer(sender, recipient, amountReceived);
        if (!isDividendExempt[sender]) {
            setShare(sender, balanceOf(sender));
        }
        if (!isDividendExempt[recipient]) {
            setShare(recipient, balanceOf(recipient));
        }
        if (shares[recipient].amount > 0) {
            distributeDividend(recipient);
        }
    }

    /// @notice Updates fee structure
    /// @param _liquidity Liquidity fee (basis points)
    /// @param _marketing Marketing fee (basis points)
    /// @param _rewards Rewards fee (basis points)
    /// @param _development Development fee (basis points)
    /// @param _total Buy fee (basis points)
    /// @param _sell Sell fee (basis points)
    /// @param _trans Transfer fee (basis points)
    function setStructure(
        uint256 _liquidity,
        uint256 _marketing,
        uint256 _rewards,
        uint256 _development,
        uint256 _total,
        uint256 _sell,
        uint256 _trans
    ) external onlyOwner {
        require(_liquidity + _marketing + _rewards + _development == denominator, "Fee components must sum to 100%");
        liquidityFee = _liquidity;
        marketingFee = _marketing;
        rewardsFee = _rewards;
        developmentFee = _development;
        totalFee = _total;
        sellFee = _sell;
        transferFee = _trans;
    }

    /// @notice Flags an address as a bot
    /// @param _address The address to flag
    /// @param _enabled True to flag as bot, false to unflag
    function setisBot(address _address, bool _enabled) external onlyOwner {
        require(_address != address(pair) && _address != address(router) && _address != address(this), "Ineligible Address");
        isBot[_address] = _enabled;
    }

    /// @notice Updates transaction and wallet limits
    /// @param _maxTx Maximum transaction limit (basis points)
    /// @param _maxSell Maximum sell limit (basis points)
    /// @param _maxWallet Maximum wallet limit (basis points)
    function setParameters(uint256 _maxTx, uint256 _maxSell, uint256 _maxWallet) external onlyOwner {
        uint256 newTx = (_totalSupply * _maxTx) / 10_000;
        uint256 newSell = (_totalSupply * _maxSell) / 10_000;
        uint256 newWallet = (_totalSupply * _maxWallet) / 10_000;
        _maxTxAmount = newTx;
        _maxSellAmount = newSell;
        _maxWalletToken = newWallet;
        uint256 limit = _totalSupply * 5 / 1000;
        require(newTx >= limit && newSell >= limit && newWallet >= limit, "Limits cannot be less than 0.5%");
        require(_maxTx <= 500 && _maxSell <= 500 && _maxWallet <= 500, "Limits cannot exceed 5%");
    }

    /// @notice Checks if trading is allowed
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    function checkTradingAllowed(address sender, address recipient) internal view {
        if (!isFeeExempt[sender] && !isFeeExempt[recipient]) {
            require(tradingAllowed, "Trading not allowed");
        }
    }

    /// @notice Checks if transfer exceeds maximum wallet limit
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    function checkMaxWallet(address sender, address recipient, uint256 amount) internal view {
        if (!isFeeExempt[sender] && !isFeeExempt[recipient] && recipient != address(pair) && recipient != address(DEAD)) {
            require((_balances[recipient] + amount) <= _maxWalletToken, "Exceeds maximum wallet amount");
        }
    }

    /// @notice Updates swap counters for triggering swaps
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    function swapbackCounters(address sender, address recipient) internal {
        if (recipient == pair && !isFeeExempt[sender]) {
            swapTimes += 1;
        }
    }

    /// @notice Checks if transfer exceeds transaction limits
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    function checkTxLimit(address sender, address recipient, uint256 amount) internal view {
        if (sender != pair) {
            require(amount <= _maxSellAmount || isFeeExempt[sender] || isFeeExempt[recipient], "Sell Limit Exceeded");
        }
        require(amount <= _maxTxAmount || isFeeExempt[sender] || isFeeExempt[recipient], "TX Limit Exceeded");
    }

    /// @notice Safely transfers ETH to a receiver
    /// @param to The receiver's address
    /// @param value The amount of ETH
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}("");
        require(success, "ETH transfer failed");
    }

    /// @notice Swaps accumulated tokens for ETH and distributes fees
    /// @param tokens The amount of tokens to swap
    function swapAndLiquify(uint256 tokens) private lockTheSwap {
        uint256 tokensToAddLiquidityWith = tokens * liquidityFee / denominator;
        uint256 toSwap = tokens - tokensToAddLiquidityWith;
        uint256 initialBalance = address(this).balance;
        swapTokensForETH(toSwap);
        uint256 deltaBalance = address(this).balance - initialBalance;

        uint256 ETHToAddLiquidityWith = deltaBalance * liquidityFee / denominator;
        uint256 marketingAmount = deltaBalance * marketingFee / denominator;
        uint256 rewardsAmount = deltaBalance * rewardsFee / denominator;
        uint256 developmentAmount = deltaBalance * developmentFee / denominator;

        if (ETHToAddLiquidityWith > 0) {
            addLiquidity(tokensToAddLiquidityWith, ETHToAddLiquidityWith);
        }
        if (marketingAmount > 0) {
            safeTransferETH(marketing_receiver, marketingAmount);
            emit ETHTransferred(marketing_receiver, marketingAmount);
        }
        if (developmentAmount > 0) {
            safeTransferETH(development_receiver, developmentAmount);
            emit ETHTransferred(development_receiver, developmentAmount);
        }
        if (rewardsAmount > 0) {
            deposit(rewardsAmount);
        }

        // Handle dust
        if (address(this).balance > 0) {
            uint256 remainingBalance = address(this).balance;
            uint256 totalNonLiquidityFee = marketingFee + rewardsFee + developmentFee;
            uint256 marketingDust = remainingBalance * marketingFee / totalNonLiquidityFee;
            uint256 rewardsDust = remainingBalance * rewardsFee / totalNonLiquidityFee;
            uint256 developmentDust = remainingBalance - marketingDust - rewardsDust;
            if (marketingDust > 0) {
                safeTransferETH(marketing_receiver, marketingDust);
                emit ETHTransferred(marketing_receiver, marketingDust);
            }
            if (developmentDust > 0) {
                safeTransferETH(development_receiver, developmentDust);
                emit ETHTransferred(development_receiver, developmentDust);
            }
            if (rewardsDust > 0) {
                deposit(rewardsDust);
            }
        }
    }

    /// @notice Adds liquidity to the BOL/WETH pair
    /// @param tokenAmount The amount of BOL tokens
    /// @param ETHAmount The amount of ETH
    function addLiquidity(uint256 tokenAmount, uint256 ETHAmount) private {
        uint256 amountTokenMin = tokenAmount * liquiditySlippageTolerance / 10_000;
        uint256 amountETHMin = ETHAmount * liquiditySlippageTolerance / 10_000;
        _approve(address(this), address(router), tokenAmount);
        router.addLiquidityETH{value: ETHAmount}(
            address(this),
            tokenAmount,
            amountTokenMin,
            amountETHMin,
            liquidity_receiver,
            block.timestamp
        );
        emit LiquidityAdded(tokenAmount, ETHAmount, amountTokenMin, amountETHMin);
    }

    /// @notice Swaps BOL tokens for ETH with failure handling
    /// @param tokenAmount The amount of tokens to swap
    function swapTokensForETH(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _approve(address(this), address(router), tokenAmount);
        uint256 amountOutMin = router.getAmountsOut(tokenAmount, path)[1] * 95 / 100;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        ) {
            emit SwapEvent(address(this), tokenAmount, amountOutMin, true, "ETH swap successful");
        } catch {
            queuedTokens += tokenAmount;
            emit SwapEvent(address(this), tokenAmount, amountOutMin, false, "ETH swap failed");
        }
    }

    /// @notice Retries failed swaps after a timelock
    /// @param tokenAmount The amount of tokens to retry
    function retrySwap(uint256 tokenAmount) external onlyOwner onlyAfterTimelock {
        require(tokenAmount <= queuedTokens, "Insufficient queued tokens");
        queuedTokens -= tokenAmount;
        lastRetryAttempt = block.timestamp;
        swapTokensForETH(tokenAmount);
        emit SwapRetryTriggered(tokenAmount);
    }

    /// @notice Checks if a swap should be triggered
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    /// @return True if swap should occur
    function shouldSwapBack(address sender, address recipient, uint256 amount) internal view returns (bool) {
        bool aboveMin = amount >= _minTokenAmount;
        bool aboveThreshold = balanceOf(address(this)) >= swapThreshold;
        return !swapping && swapEnabled && tradingAllowed && aboveMin && !isFeeExempt[sender] && recipient == pair && swapTimes >= 2 && aboveThreshold;
    }

    /// @notice Triggers a swap if conditions are met
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    function swapBack(address sender, address recipient, uint256 amount) internal {
        if (shouldSwapBack(sender, recipient, amount)) {
            swapAndLiquify(swapThreshold);
            swapTimes = 0;
        }
    }

    /// @notice Manually triggers a swap
    function triggerSwap() external onlyOwner nonReentrant {
        require(balanceOf(address(this)) >= swapThreshold, "Insufficient tokens for swap");
        require(swapEnabled, "Swaps are disabled");
        require(tradingAllowed, "Trading is not allowed");
        swapAndLiquify(swapThreshold);
        swapTimes = 0;
    }

    /// @notice Checks if fees should be applied
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @return True if fees apply
    function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        return !isFeeExempt[sender] && !isFeeExempt[recipient];
    }

    /// @notice Calculates the total fee for a transaction
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @return The total fee in basis points
    function getTotalFee(address sender, address recipient) internal view returns (uint256) {
        if (isBot[sender] || isBot[recipient]) {
            return denominator - 100;
        }
        if (recipient == pair) {
            return sellFee;
        }
        if (sender == pair) {
            return totalFee;
        }
        return transferFee;
    }

    /// @notice Applies fees to a transfer
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    /// @return The amount after fees
    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount * getTotalFee(sender, recipient) / denominator;
        if (feeAmount > 0) {
            _balances[address(this)] += feeAmount;
            emit Transfer(sender, address(this), feeAmount);
        }
        return amount - feeAmount;
    }

    /// @notice Transfers tokens from sender to recipient with allowance
    /// @param sender The sender's address
    /// @param recipient The recipient's address
    /// @param amount The transfer amount
    /// @return True if successful
    function transferFrom(address sender, address recipient, uint256 amount) public override nonReentrant returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender] - amount);
        return true;
    }

    /// @notice Approves a spender internally
    /// @param owner_ The owner's address
    /// @param spender The spender's address
    /// @param amount The amount to approve
    function _approve(address owner_, address spender, uint256 amount) private {
        require(owner_ != address(0) && spender != address(0), "Invalid address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    /// @notice Sets dividend exemption status for a holder
    /// @param holder The holder's address
    /// @param exempt True to exempt, false to include
    function setisDividendExempt(address holder, bool exempt) external onlyOwner {
        isDividendExempt[holder] = exempt;
        if (exempt) {
            setShare(holder, 0);
        } else {
            setShare(holder, balanceOf(holder));
        }
    }

    /// @notice Updates shareholder's share for dividends
    /// @param shareholder The shareholder's address
    /// @param amount The new share amount
    function setShare(address shareholder, uint256 amount) internal {
        bool wasShareholder = isShareholder[shareholder];
        if (amount > 0 && !wasShareholder) {
            isShareholder[shareholder] = true;
        } else if (amount == 0 && wasShareholder) {
            isShareholder[shareholder] = false;
        }
        totalShares = uint128(totalShares - shares[shareholder].amount + amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(amount);
    }

    /// @notice Swaps ETH for USDC to fund dividends
    /// @param amountETH The amount of ETH to swap
    function deposit(uint256 amountETH) internal {
        uint256 balanceBefore = IERC20(reward).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(reward);
        uint256 amountOutMin = getMinUSDCOutput(amountETH) * 95 / 100;
        try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountETH}(
            amountOutMin,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 amount = IERC20(reward).balanceOf(address(this)) - balanceBefore;
            uint256 adjustedAmount = normalizeTo18Decimals(amount);
            totalDividends += adjustedAmount;
            dividendsPerShare += dividendsPerShareAccuracyFactor * adjustedAmount / totalShares;
            emit SwapEvent(reward, amountETH, amount, true, "USDC swap successful");
        } catch {
            emit SwapEvent(reward, amountETH, amountOutMin, false, "USDC swap failed");
            // Do not revert; allow partial execution
        }
    }

    /// @notice Normalizes USDC amount to 18 decimals for internal calculations
    /// @param amount The USDC amount
    /// @return The normalized amount
    function normalizeTo18Decimals(uint256 amount) internal view returns (uint256) {
        if (rewardDecimals == 18) return amount;
        return amount * (10**(18 - rewardDecimals));
    }

    /// @notice Denormalizes amount from 18 decimals to USDC decimals
    /// @param amount The normalized amount
    /// @return The denormalized amount
    function denormalizeFrom18Decimals(uint256 amount) internal view returns (uint256) {
        if (rewardDecimals == 18) return amount;
        return amount / (10**(18 - rewardDecimals));
    }

    /// @notice Calculates minimum USDC output for ETH swap
    /// @param amountETH The amount of ETH
    /// @return The minimum USDC output
    function getMinUSDCOutput(uint256 amountETH) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(reward);
        return router.getAmountsOut(amountETH, path)[1];
    }



    /// @notice Distributes dividends to a single shareholder
    /// @param shareholder The shareholder's address
    function distributeDividend(address shareholder) internal {
        if (shares[shareholder].amount == 0) {
            return;
        }
        uint256 amount = getUnpaidEarnings(shareholder);
        if (amount > 0 && IERC20(reward).balanceOf(address(this)) >= denormalizeFrom18Decimals(amount)) {
            uint256 adjustedAmount = denormalizeFrom18Decimals(amount);
            totalDistributed += amount;
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised += amount;
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
            IERC20(reward).safeTransfer(shareholder, adjustedAmount);
            emit DividendsDistributed(shareholder, adjustedAmount);
        }
    }

    /// @notice Allows users to claim their USDC dividends
    function claimDividend() external nonReentrant {
        distributeDividend(msg.sender);
    }

    /// @notice Rescues ERC20 tokens in emergency situations
    /// @param _address The token address
    /// @param _amount The amount to rescue
    function rescueERC20(address _address, uint256 _amount) external onlyOwner {
        IERC20(_address).safeTransfer(marketing_receiver, _amount);
    }

    /// @notice Checks if a shareholder is eligible for dividend distribution
    /// @param shareholder The shareholder's address
    /// @return True if eligible
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp && getUnpaidEarnings(shareholder) > minDistribution;
    }

    /// @notice Returns the total USDC rewards distributed to a wallet
    /// @param _wallet The wallet address
    /// @return The total distributed amount
    function totalRewardsDistributed(address _wallet) external view returns (uint256) {
        return shares[_wallet].totalRealised;
    }

    /// @notice Returns unpaid USDC earnings for a shareholder
    /// @param shareholder The shareholder's address
    /// @return The unpaid earnings
    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if (shares[shareholder].amount == 0) {
            return 0;
        }
        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        return shareholderTotalDividends > shares[shareholder].totalExcluded ? shareholderTotalDividends - shares[shareholder].totalExcluded : 0;
    }

    /// @notice Calculates cumulative dividends for a share amount
    /// @param share The share amount
    /// @return The cumulative dividends
    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return (share * dividendsPerShare) / dividendsPerShareAccuracyFactor;
    }

    /// @notice Sets criteria for dividend distribution
    /// @param _minPeriod Minimum period between distributions
    /// @param _minDistribution Minimum USDC amount for distribution
    /// @param _distributorGas Gas limit for batch distribution
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, uint256 _distributorGas) external onlyOwner {
        require(_distributorGas >= 100_000 && _distributorGas <= 1_000_000, "Distributor gas must be between 100,000 and 1,000,000");
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        distributorGas = _distributorGas;
    }

    /// @notice Sets fee exemption status for an address
    /// @param _address The address to set
    /// @param _enabled True to exempt, false to include
    function setisExempt(address _address, bool _enabled) external onlyOwner {
        isFeeExempt[_address] = _enabled;
    }

    /// @notice Returns the current fee structure
    /// @return _buyFee The buy fee in basis points
    /// @return _sellFee The sell fee in basis points
    /// @return _transferFee The transfer fee in basis points
    /// @return _distribution Array of fee distributions [liquidity, marketing, rewards, development]
    function getFeeStructure() external view returns (uint256 _buyFee, uint256 _sellFee, uint256 _transferFee, uint256[4] memory _distribution) {
        return (totalFee, sellFee, transferFee, [liquidityFee, marketingFee, rewardsFee, developmentFee]);
    }

    /// @notice Estimates USDC rewards for a holder
    /// @param holder The holder's address
    /// @return usdcAmount The estimated USDC rewards
    function estimateRewards(address holder) external view returns (uint256 usdcAmount) {
        return denormalizeFrom18Decimals(getUnpaidEarnings(holder));
    }

    /// @notice Returns contract statistics
    /// @return _totalDividends Total USDC dividends accumulated
    /// @return _totalDistributed Total USDC dividends distributed
    /// @return _totalShares Total shares for dividend calculation
    /// @return _queuedTokens Tokens queued for swap retries
    function getContractStats() external view returns (
        uint256 _totalDividends,
        uint256 _totalDistributed,
        uint256 _totalShares,
        uint256 _queuedTokens
    ) {
        return (totalDividends, totalDistributed, totalShares, queuedTokens);
    }

    /// @notice Returns holder information
    /// @param holder The holder's address
    /// @return _balance The BOL token balance
    /// @return _shares The dividend shares
    /// @return _unpaidDividends The unpaid USDC dividends
    function getHolderInfo(address holder) external view returns (
        uint256 _balance,
        uint256 _shares,
        uint256 _unpaidDividends
    ) {
        return (balanceOf(holder), shares[holder].amount, getUnpaidEarnings(holder));
    }

    /// @notice Returns swap configuration
    /// @return _swapEnabled Whether swaps are enabled
    /// @return _swapThreshold Minimum tokens required for a swap
    /// @return _minTokenAmountOut Minimum token amount for swap triggering
    /// @return _swapTimes Number of swaps since last reset
    function getSwapConfig() external view returns (
        bool _swapEnabled,
        uint256 _swapThreshold,
        uint256 _minTokenAmountOut,
        uint256 _swapTimes
    ) {
        return (swapEnabled, swapThreshold, _minTokenAmount, swapTimes);
    }
}
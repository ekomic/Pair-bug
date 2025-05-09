// THIS IS A TEST TOKEN, NO NEED BUYING!
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

    function transferOwnership(address payable adr) public onlyOwner {
        require(adr != address(0), "Owner cannot be zero address");
        owner = adr;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

interface IFactory {
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);
}

interface IRouter {
    function factory() external pure returns (address);
    function wETH() external pure returns (address);
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

contract DoNotBuy is IERC20Extended, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string private constant _name = "Do Not Buy";
    string private constant _symbol = "DNB";
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

    mapping(address => uint256) private shareholderClaims;
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }
    mapping(address => Share) public shares;
    mapping(address => bool) private isShareholder;

    uint256 public minPeriod = 60 minutes;
    uint256 public minDistribution = 1 * (10**16); // 0.01 USDC
    uint256 public distributorGas = 350_000;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public development_receiver;
    address public marketing_receiver;
    address public liquidity_receiver;
    uint256 public liquiditySlippageTolerance = 9500; // 95% (5% slippage)

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

    constructor(address routerAddress, address usdcAddress) Ownable(msg.sender) {
        require(routerAddress != address(0), "Router cannot be zero address");
        require(usdcAddress != address(0), "USDC cannot be zero address");

        IRouter _router = IRouter(routerAddress);
        router = _router;
        // Fix: Create or retrieve the DNB/WETH pair
        address _pair = IFactory(_router.factory()).getPair(address(this), _router.wETH(), false);
        if (_pair == address(0)) {
            _pair = IFactory(_router.factory()).createPair(address(this), _router.wETH(), false);
        }
        pair = _pair;
        reward = usdcAddress;
        rewardDecimals = 6;
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

    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function setLiquiditySlippageTolerance(uint256 _tolerance) external onlyOwner {
        require(_tolerance >= 8500 && _tolerance <= 9800, "Tolerance must be between 85% and 98%");
        liquiditySlippageTolerance = _tolerance;
        emit SlippageToleranceUpdated(_tolerance);
    }

    function setRouter(address _routerAddress) external onlyOwner {
        require(_routerAddress != address(0), "Router cannot be zero address");
        router = IRouter(_routerAddress);
        pair = IFactory(router.factory()).getPair(address(this), router.wETH(), false);
        if (pair == address(0)) {
            pair = IFactory(router.factory()).createPair(address(this), router.wETH(), false);
        }
        emit RouterUpdated(_routerAddress);
    }

    function setReward(address _usdcAddress) external onlyOwner {
        require(_usdcAddress != address(0), "USDC cannot be zero address");
        uint8 usdcDecimals = IERC20Metadata(_usdcAddress).decimals();
        require(usdcDecimals >= 6 && usdcDecimals <= 18, "Reward token decimals must be 6 to 18");
        reward = _usdcAddress;
        rewardDecimals = usdcDecimals;
        emit RewardUpdated(_usdcAddress);
    }

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

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function getOwner() external view override returns (address) {
        return owner;
    }

    function totalSupply() public pure override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override nonReentrant returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function circulatingSupply() public view override returns (uint256) {
        return _totalSupply - balanceOf(DEAD) - balanceOf(address(0));
    }

    function startTrading() external onlyOwner {
        require(!tradingAllowed, "Trading is already open");
        tradingAllowed = true;
    }

    function preTxCheck(address sender, uint256 amount) internal view {
        require(amount > 0, "Transfer amount must be greater than zero");
        require(amount <= balanceOf(sender), "Insufficient balance");
    }

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

    function setisBot(address _address, bool _enabled) external onlyOwner {
        require(_address != address(pair) && _address != address(router) && _address != address(this), "Ineligible Address");
        isBot[_address] = _enabled;
    }

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

    function checkTradingAllowed(address sender, address recipient) internal view {
        if (!isFeeExempt[sender] && !isFeeExempt[recipient]) {
            require(tradingAllowed, "Trading not allowed");
        }
    }

    function checkMaxWallet(address sender, address recipient, uint256 amount) internal view {
        if (!isFeeExempt[sender] && !isFeeExempt[recipient] && recipient != address(pair) && recipient != address(DEAD)) {
            require((_balances[recipient] + amount) <= _maxWalletToken, "Exceeds maximum wallet amount");
        }
    }

    function swapbackCounters(address sender, address recipient) internal {
        if (recipient == pair && !isFeeExempt[sender]) {
            swapTimes += 1;
        }
    }

    function checkTxLimit(address sender, address recipient, uint256 amount) internal view {
        if (sender != pair) {
            require(amount <= _maxSellAmount || isFeeExempt[sender] || isFeeExempt[recipient], "Sell Limit Exceeded");
        }
        require(amount <= _maxTxAmount || isFeeExempt[sender] || isFeeExempt[recipient], "TX Limit Exceeded");
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}("");
        require(success, "ETH transfer failed");
    }

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

    function swapTokensForETH(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.wETH();
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

    function retrySwap(uint256 tokenAmount) external onlyOwner onlyAfterTimelock {
        require(tokenAmount <= queuedTokens, "Insufficient queued tokens");
        queuedTokens -= tokenAmount;
        lastRetryAttempt = block.timestamp;
        swapTokensForETH(tokenAmount);
        emit SwapRetryTriggered(tokenAmount);
    }

    function shouldSwapBack(address sender, address recipient, uint256 amount) internal view returns (bool) {
        bool aboveMin = amount >= _minTokenAmount;
        bool aboveThreshold = balanceOf(address(this)) >= swapThreshold;
        return !swapping && swapEnabled && tradingAllowed && aboveMin && !isFeeExempt[sender] && recipient == pair && swapTimes >= 2 && aboveThreshold;
    }

    function swapBack(address sender, address recipient, uint256 amount) internal {
        if (shouldSwapBack(sender, recipient, amount)) {
            swapAndLiquify(swapThreshold);
            swapTimes = 0;
        }
    }

    function triggerSwap() external onlyOwner nonReentrant {
        require(balanceOf(address(this)) >= swapThreshold, "Insufficient tokens for swap");
        require(swapEnabled, "Swaps are disabled");
        require(tradingAllowed, "Trading is not allowed");
        swapAndLiquify(swapThreshold);
        swapTimes = 0;
    }

    function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        return !isFeeExempt[sender] && !isFeeExempt[recipient];
    }

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

    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount * getTotalFee(sender, recipient) / denominator;
        if (feeAmount > 0) {
            _balances[address(this)] += feeAmount;
            emit Transfer(sender, address(this), feeAmount);
        }
        return amount - feeAmount;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override nonReentrant returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender] - amount);
        return true;
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        require(owner_ != address(0) && spender != address(0), "Invalid address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function setisDividendExempt(address holder, bool exempt) external onlyOwner {
        isDividendExempt[holder] = exempt;
        if (exempt) {
            setShare(holder, 0);
        } else {
            setShare(holder, balanceOf(holder));
        }
    }

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

    function deposit(uint256 amountETH) internal {
        uint256 balanceBefore = IERC20(reward).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = router.wETH();
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
        }
    }

    function normalizeTo18Decimals(uint256 amount) internal view returns (uint256) {
        if (rewardDecimals == 18) return amount;
        return amount * (10**(18 - rewardDecimals));
    }

    function denormalizeFrom18Decimals(uint256 amount) internal view returns (uint256) {
        if (rewardDecimals == 18) return amount;
        return amount / (10**(18 - rewardDecimals));
    }

    function getMinUSDCOutput(uint256 amountETH) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = router.wETH();
        path[1] = address(reward);
        return router.getAmountsOut(amountETH, path)[1];
    }

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

    function claimDividend() external nonReentrant {
        distributeDividend(msg.sender);
    }

    function rescueERC20(address _address, uint256 _amount) external onlyOwner {
        IERC20(_address).safeTransfer(marketing_receiver, _amount);
    }

    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function totalRewardsDistributed(address _wallet) external view returns (uint256) {
        return shares[_wallet].totalRealised;
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if (shares[shareholder].amount == 0) {
            return 0;
        }
        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        return shareholderTotalDividends > shares[shareholder].totalExcluded ? shareholderTotalDividends - shares[shareholder].totalExcluded : 0;
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return (share * dividendsPerShare) / dividendsPerShareAccuracyFactor;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, uint256 _distributorGas) external onlyOwner {
        require(_distributorGas >= 100_000 && _distributorGas <= 1_000_000, "Distributor gas must be between 100,000 and 1,000,000");
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        distributorGas = _distributorGas;
    }

    function setisExempt(address _address, bool _enabled) external onlyOwner {
        isFeeExempt[_address] = _enabled;
    }

    function getFeeStructure() external view returns (uint256 _buyFee, uint256 _sellFee, uint256 _transferFee, uint256[4] memory _distribution) {
        return (totalFee, sellFee, transferFee, [liquidityFee, marketingFee, rewardsFee, developmentFee]);
    }

    function estimateRewards(address holder) external view returns (uint256 usdcAmount) {
        return denormalizeFrom18Decimals(getUnpaidEarnings(holder));
    }

    function getContractStats() external view returns (
        uint256 _totalDividends,
        uint256 _totalDistributed,
        uint256 _totalShares,
        uint256 _queuedTokens
    ) {
        return (totalDividends, totalDistributed, totalShares, queuedTokens);
    }

    function getHolderInfo(address holder) external view returns (
        uint256 _balance,
        uint256 _shares,
        uint256 _unpaidDividends
    ) {
        return (balanceOf(holder), shares[holder].amount, getUnpaidEarnings(holder));
    }

    function getSwapConfig() external view returns (
        bool _swapEnabled,
        uint256 _swapThreshold,
        uint256 _minTokenAmountOut,
        uint256 _swapTimes
    ) {
        return (swapEnabled, swapThreshold, _minTokenAmount, swapTimes);
    }
}
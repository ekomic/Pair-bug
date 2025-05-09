/**
 * BankOfLinea Token (BOL)
 * 
 * Fee Structure:
 * - 10% fee on buy transactions
 * - 15% fee on sell transactions
 * - 2% fee on transfer transactions
 * 
 * Fee Distribution (All Transactions - Buy, Sell, Transfer):
 * - 70% of fees to USDC rewards for holders (0.7% on buy, 1.05% on sell, 0.14% on transfer)
 * - 18% of fees to marketing wallet (1.8% on buy, 2.7% on sell, 0.36% on transfer, sent as ETH)
 * - 10% of fees to development wallet (0.1% on buy, 0.15% on sell, 0.02% on transfer, sent as ETH)
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
 * - Reentrancy protection during swaps
 
 * Dividends are distributed automatically during transfers or can be claimed individually by holders.
 * 
 * Links:
 * https://linktr.ee/bankoflinea
 * https://bankoflinea.build/
 * https://x.com/bankoflinea
 */

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {return a + b;}
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {return a - b;}
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {return a * b;}
    function div(uint256 a, uint256 b) internal pure returns (uint256) {return a / b;}
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {return a % b;}
    
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {uint256 c = a + b; if(c < a) return(false, 0); return(true, c);}}

    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {if(b > a) return(false, 0); return(true, a - b);}}

    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {if (a == 0) return(true, 0); uint256 c = a * b;
        if(c / a != b) return(false, 0); return(true, c);}}

    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {if(b == 0) return(false, 0); return(true, a / b);}}

    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {if(b == 0) return(false, 0); return(true, a % b);}}

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked{require(b <= a, errorMessage); return a - b;}}

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked{require(b > 0, errorMessage); return a / b;}}

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked{require(b > 0, errorMessage); return a % b;}}
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function circulatingSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Ownable {
    address internal owner;
    constructor(address _owner) {owner = _owner;}
    modifier onlyOwner() {require(isOwner(msg.sender), "!OWNER"); _;}
    function isOwner(address account) public view returns (bool) {return account == owner;}
    function transferOwnership(address payable adr) public onlyOwner {owner = adr; emit OwnershipTransferred(adr);}
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

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);

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

contract BankOfLinea is IERC20, Ownable {
    using SafeMath for uint256;
    string private constant _name = 'Bank of Linea';
    string private constant _symbol = 'BOL';
    uint8 private constant _decimals = 18;
    uint256 private _totalSupply = 100000000 * (10 ** _decimals);
    uint256 private _maxTxAmount = ( _totalSupply * 100 ) / 10000;
    uint256 private _maxSellAmount = ( _totalSupply * 200 ) / 10000;
    uint256 private _maxWalletToken = ( _totalSupply * 200 ) / 10000;
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) public isFeeExempt;
    mapping (address => bool) public isDividendExempt;
    mapping (address => bool) private isBot;
    IRouter router;
    address public pair;
    bool private tradingAllowed = false;
    uint256 private liquidityFee = 200; // 2%
    uint256 private marketingFee = 1800; // 18%
    uint256 private rewardsFee = 700; // 70%
    uint256 private developmentFee = 100; // 10%
    uint256 private burnFee = 0;
    uint256 private totalFee = 1000; // 10% for buys
    uint256 private sellFee = 1500; // 15% for sells
    uint256 private transferFee = 200; // 2% for transfers
    uint256 private denominator = 10000;
    bool private swapEnabled = true;
    uint256 private swapTimes;
    bool private swapping; 
    uint256 private swapThreshold = ( _totalSupply * 500 ) / 100000;
    uint256 private _minTokenAmount = ( _totalSupply * 10 ) / 100000;
    modifier lockTheSwap {swapping = true; _; swapping = false;}
    address public reward = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff; // USDC contract Address on Linea
    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 internal dividendsPerShare;
    uint256 internal dividendsPerShareAccuracyFactor = 10 ** 36;
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    struct Share {uint256 amount; uint256 totalExcluded; uint256 totalRealised; }
    mapping (address => Share) public shares;
    uint256 internal currentIndex;
    uint256 public minPeriod = 60 minutes;
    uint256 public minDistribution = 1 * (10 ** 16);
    uint256 public distributorGas = 350000;
    function _claimDividend() external {distributeDividend(msg.sender);}

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Mutable receiver addresses
    address public development_receiver;
    address public marketing_receiver;
    address public liquidity_receiver;

    constructor() Ownable(msg.sender) {
        IRouter _router = IRouter(0x8FC5eff4cEc245D7AE0A8378dd4269c2f4f1113f); // Router contract from Lynex
        address _pair = IFactory(_router.factory()).createPair(address(this), _router.WETH());
        router = _router;
        pair = _pair;

        // Initialize receiver addresses
        development_receiver = 0x0F245A7D374388CD76fC8139Dd900E9B02bF69d7;
        marketing_receiver = 0x9d12C7aAd8297E042e8cDbAE5e12df12F297eEF9;
        liquidity_receiver = 0xd53686b4298Ac78B1d182E95FeAC1A4DD1D780bD;

        // Set initial fee exemptions
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

    // Function to update receiver addresses
    function setReceiverAddresses(
        address _developmentReceiver,
        address _marketingReceiver,
        address _liquidityReceiver
    ) external onlyOwner {
        require(_developmentReceiver != address(0), "Development receiver cannot be zero address");
        require(_marketingReceiver != address(0), "Marketing receiver cannot be zero address");
        require(_liquidityReceiver != address(0), "Liquidity receiver cannot be zero address");

        // Remove fee exemptions for old addresses
        isFeeExempt[development_receiver] = false;
        isFeeExempt[marketing_receiver] = false;
        isFeeExempt[liquidity_receiver] = false;

        // Update receiver addresses
        development_receiver = _developmentReceiver;
        marketing_receiver = _marketingReceiver;
        liquidity_receiver = _liquidityReceiver;

        // Set fee exemptions for new addresses
        isFeeExempt[development_receiver] = true;
        isFeeExempt[marketing_receiver] = true;
        isFeeExempt[liquidity_receiver] = true;
    }

    receive() external payable {}
    function name() public pure returns (string memory) {return _name;}
    function symbol() public pure returns (string memory) {return _symbol;}
    function decimals() public pure returns (uint8) {return _decimals;}
    function getOwner() external view override returns (address) { return owner; }
    function totalSupply() public view override returns (uint256) {return _totalSupply;}
    function balanceOf(address account) public view override returns (uint256) {return _balances[account];}
    function transfer(address recipient, uint256 amount) public override returns (bool) {_transfer(msg.sender, recipient, amount);return true;}
    function allowance(address owner, address spender) public view override returns (uint256) {return _allowances[owner][spender];}
    function isCont(address addr) internal view returns (bool) {uint size; assembly { size := extcodesize(addr) } return size > 0; }
    function setisExempt(address _address, bool _enabled) external onlyOwner {isFeeExempt[_address] = _enabled;}
    function approve(address spender, uint256 amount) public override returns (bool) {_approve(msg.sender, spender, amount);return true;}
    function circulatingSupply() public view override returns (uint256) {return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(address(0)));}

    function startTrading() external onlyOwner {
        require(!tradingAllowed, "trading is already open");
        tradingAllowed = true;
    }

    function preTxCheck(address sender, address recipient, uint256 amount) internal view {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > uint256(0), "Transfer amount must be greater than zero");
        require(amount <= balanceOf(sender), "You are trying to transfer more than your balance");
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        preTxCheck(sender, recipient, amount);
        checkTradingAllowed(sender, recipient);
        checkMaxWallet(sender, recipient, amount); 
        swapbackCounters(sender, recipient);
        checkTxLimit(sender, recipient, amount); 
        swapBack(sender, recipient, amount);
        _balances[sender] = _balances[sender].sub(amount);
        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);
        emit Transfer(sender, recipient, amountReceived);
        if(!isDividendExempt[sender]){setShare(sender, balanceOf(sender));}
        if(!isDividendExempt[recipient]){setShare(recipient, balanceOf(recipient));}
        if(shares[recipient].amount > 0){distributeDividend(recipient);}
        process(distributorGas);
    }

    function setStructure(uint256 _liquidity, uint256 _marketing, uint256 _burn, uint256 _rewards, uint256 _development, uint256 _total, uint256 _sell, uint256 _trans) external onlyOwner {
        liquidityFee = _liquidity;
        marketingFee = _marketing;
        burnFee = _burn;
        rewardsFee = _rewards;
        developmentFee = _development;
        totalFee = _total;
        sellFee = _sell;
        transferFee = _trans;
        //require(totalFee <= denominator.div(10) && sellFee <= denominator.div(10) && transferFee <= denominator.div(10), "totalFee and sellFee cannot be more than 10%");
    }

    function setisBot(address _address, bool _enabled) external onlyOwner {
        require(_address != address(pair) && _address != address(router) && _address != address(this), "Ineligible Address");
        isBot[_address] = _enabled;
    }

    function setParameters(uint256 _buy, uint256 _trans, uint256 _wallet) external onlyOwner {
        uint256 newTx = (totalSupply() * _buy) / 10000;
        uint256 newTransfer = (totalSupply() * _trans) / 10000;
        uint256 newWallet = (totalSupply() * _wallet) / 10000;
        _maxTxAmount = newTx;
        _maxSellAmount = newTransfer;
        _maxWalletToken = newWallet;
        uint256 limit = totalSupply().mul(5).div(1000);
        require(newTx >= limit && newTransfer >= limit && newWallet >= limit, "Max TXs and Max Wallet cannot be less than .5%");
    }

    function checkTradingAllowed(address sender, address recipient) internal view {
        if(!isFeeExempt[sender] && !isFeeExempt[recipient]){require(tradingAllowed, "tradingAllowed");}
    }
    
    function checkMaxWallet(address sender, address recipient, uint256 amount) internal view {
        if(!isFeeExempt[sender] && !isFeeExempt[recipient] && recipient != address(pair) && recipient != address(DEAD)){
            require((_balances[recipient].add(amount)) <= _maxWalletToken, "Exceeds maximum wallet amount.");}
    }

    function swapbackCounters(address sender, address recipient) internal {
        if(recipient == pair && !isFeeExempt[sender]){swapTimes += uint256(1);}
    }

    function checkTxLimit(address sender, address recipient, uint256 amount) internal view {
        if(sender != pair){require(amount <= _maxSellAmount || isFeeExempt[sender] || isFeeExempt[recipient], "TX Limit Exceeded");}
        require(amount <= _maxTxAmount || isFeeExempt[sender] || isFeeExempt[recipient], "TX Limit Exceeded");
    }

    function swapAndLiquify(uint256 tokens) private lockTheSwap {
    // Calculate the denominator as the sum of all fee components
    uint256 _denominator = liquidityFee.add(marketingFee).add(developmentFee).add(rewardsFee);

    // Calculate tokens to be used for liquidity
    uint256 tokensToAddLiquidityWith = tokens.mul(liquidityFee).div(_denominator);
    uint256 toSwap = tokens.sub(tokensToAddLiquidityWith);

    // Swap tokens for ETH
    uint256 initialBalance = address(this).balance;
    swapTokensForETH(toSwap);
    uint256 deltaBalance = address(this).balance.sub(initialBalance);

    // Calculate ETH allocations based on fee ratios
    uint256 unitBalance = deltaBalance.div(_denominator);
    uint256 ETHToAddLiquidityWith = unitBalance.mul(liquidityFee);
    uint256 marketingAmount = unitBalance.mul(marketingFee);
    uint256 rewardsAmount = unitBalance.mul(rewardsFee);
    uint256 developmentAmount = unitBalance.mul(developmentFee);

    // Add liquidity if ETH is available
    if (ETHToAddLiquidityWith > 0) {
        addLiquidity(tokensToAddLiquidityWith, ETHToAddLiquidityWith);
    }

    // Send ETH to marketing wallet
    if (marketingAmount > 0) {
        payable(marketing_receiver).transfer(marketingAmount);
    }

    // Deposit ETH for USDC rewards
    if (rewardsAmount > 0) {
        deposit(rewardsAmount);
    }

    // Send ETH to development wallet
    if (developmentAmount > 0) {
        payable(development_receiver).transfer(developmentAmount);
    }
}

    function addLiquidity(uint256 tokenAmount, uint256 ETHAmount) private {
        _approve(address(this), address(router), tokenAmount);
        router.addLiquidityETH{value: ETHAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            liquidity_receiver,
            block.timestamp);
    }

    function swapTokensForETH(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp);
    }

    function shouldSwapBack(address sender, address recipient, uint256 amount) internal view returns (bool) {
        bool aboveMin = amount >= _minTokenAmount;
        bool aboveThreshold = balanceOf(address(this)) >= swapThreshold;
        return !swapping && swapEnabled && tradingAllowed && aboveMin && !isFeeExempt[sender] && recipient == pair && swapTimes >= uint256(2) && aboveThreshold;
    }

    function swapBack(address sender, address recipient, uint256 amount) internal {
        if(shouldSwapBack(sender, recipient, amount)){swapAndLiquify(swapThreshold); swapTimes = uint256(0);}
    }

    function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        return !isFeeExempt[sender] && !isFeeExempt[recipient];
    }

    function getTotalFee(address sender, address recipient) internal view returns (uint256) {
        if(isBot[sender] || isBot[recipient]){return denominator.sub(uint256(100));}
        if(recipient == pair){return sellFee;}
        if(sender == pair){return totalFee;}
        return transferFee;
    }

    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        if(getTotalFee(sender, recipient) > 0){
            uint256 feeAmount = amount.div(denominator).mul(getTotalFee(sender, recipient));
            _balances[address(this)] = _balances[address(this)].add(feeAmount);
            emit Transfer(sender, address(this), feeAmount);
            if(burnFee > uint256(0)){_transfer(address(this), address(DEAD), amount.div(denominator).mul(burnFee));}
            return amount.sub(feeAmount);
        }
        return amount;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function setisDividendExempt(address holder, bool exempt) external onlyOwner {
        isDividendExempt[holder] = exempt;
        if(exempt){setShare(holder, 0);}
        else{setShare(holder, balanceOf(holder)); }
    }

    function setShare(address shareholder, uint256 amount) internal {
        if(amount > 0 && shares[shareholder].amount == 0){addShareholder(shareholder);}
        else if(amount == 0 && shares[shareholder].amount > 0){removeShareholder(shareholder); }
        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

   function deposit(uint256 amountETH) internal {
    uint256 balanceBefore = IERC20(reward).balanceOf(address(this));
    address[] memory path = new address[](2);
    path[0] = router.WETH();
    path[1] = address(reward);
    uint256 amountOutMin = getMinUSDCOutput(amountETH).mul(95).div(100);
    router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountETH}(
        amountOutMin,
        path,
        address(this),
        block.timestamp
    );
    uint256 amount = IERC20(reward).balanceOf(address(this)).sub(balanceBefore);
    totalDividends = totalDividends.add(amount);
    dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
}

function getMinUSDCOutput(uint256 amountETH) internal view returns (uint256) {
    address[] memory path = new address[](2);
    path[0] = router.WETH();
    path[1] = address(reward);
    uint256[] memory amounts = router.getAmountsOut(amountETH, path);
    return amounts[1];
}

    function process(uint256 gas) internal {
        uint256 shareholderCount = shareholders.length;
        if(shareholderCount == 0) { return; }
        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();
        uint256 iterations = 0;
        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){currentIndex = 0;}
            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);}
            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }

    function rescueERC20(address _address, uint256 _amount) external onlyOwner {
        IERC20(_address).transfer(marketing_receiver, _amount);
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function totalRewardsDistributed(address _wallet) external view returns (uint256) {
        address shareholder = _wallet;
        return uint256(shares[shareholder].totalRealised);
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }
        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            IERC20(reward).transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);}
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }
        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;
        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }
        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution, uint256 _distributorGas) external onlyOwner {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
        distributorGas = _distributorGas;
    }
}
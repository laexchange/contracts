pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './LaunchSwapRouter02.sol';

contract QuotaFarmingRouter is LaunchSwapRouter02, IUniswapV2Callee {
    using TransferHelper for address;
    using TransferHelper for address payable;
    
    uint internal duration;
    uint internal creatorRatio;
    uint internal buybackRatio;
    address public LA;

	mapping (address => mapping (address => uint)) public lep;                // 1: linear, 2: exponential, 3: power
	mapping (address => mapping (address => uint)) public period;
	mapping (address => mapping (address => uint)) public begin;
    mapping (address => mapping (address => uint)) public quotasDuration;
    mapping (address => mapping (address => uint)) public periodFinish;
    mapping (address => mapping (address => uint)) public taxsBuffer;
    mapping (address => mapping (address => uint)) public quotasBuffer;
    mapping (address => mapping (address => uint)) public lastUpdateTime;                        // limitedToken => taxToken => 

    mapping (address => mapping (address => mapping (address => uint))) public swapAmounts;      // account => limitedToken => taxToken => 
    mapping (address => mapping (address => mapping (address => uint))) public swapTaxs;   
    mapping (address => mapping (address => mapping (address => uint))) public quotas;
    mapping (address => mapping (address => mapping (address => uint))) public paid;

    mapping (address => address) public quotaTokenOf;
    address[] public allLimitedTokens;
    mapping (address => address) public launchPoolOf;

    function allLimitedTokensLength() external view returns (uint) {
        return allLimitedTokens.length;
    }

    function __QuotaFarmingRouter_init(address _factory, address _WETH, address payable launchPool2, uint begin_) public initializer {
        __LaunchSwapRouter02_init(_factory, _WETH);
        __QuotaFarmingRouter_init_unchained(launchPool2, begin_);
    }

    function __QuotaFarmingRouter_init_unchained(address payable launchPool2, uint begin_) public onlySetter {
        duration = 20 days;
        creatorRatio = 0.40 ether;
        buybackRatio = 0.40 ether;
        (LA,,) = initQuotaPool2(launchPool2, "LA.exchange", "LA", "", begin_);
    }

    function initQuotaPool2(address payable pool, string memory name, string memory symbol, string memory metadata_, uint begin_) public onlySetter returns (address limitedToken, address quotaToken, address pair) {
        address[] memory WETHs = new address[](1);
        WETHs[0] = WETH;
        (limitedToken, quotaToken) = _createLimitedToken(name, symbol, metadata_, 18, 1_000_000_000e18, address(this), WETHs);
        (,,, pair) = createLiquidity0ETH(limitedToken, 1_000_000_000e18, 0.5 ether);      // 50 ether
        creator[limitedToken] = msg.sender;
        buyback[limitedToken] = limitedToken;
        launchPoolOf[limitedToken] = pool;
        LaunchPool2(pool).__LaunchPool2_init(limitedToken, quotaToken, duration, begin_);
        quotaToken.safeTransferFrom(limitedToken, pool, 1_000_000_000e18);  // / 2);
        //_notifyQuotaBegin(limitedToken, WETH, 2, 1 hours, duration, begin_);
        emit QuotaPoolCreated(name, symbol, begin_, limitedToken, quotaToken, pair, pool);
    }
    event QuotaPoolCreated(string name, string symbol, uint begin, address limitedToken, address quotaToken, address pair, address pool);

    //function createQuotaPool(string memory name, string memory symbol, string memory metadata_, uint begin_) public returns (address limitedToken, address quotaToken, address pair, address pool) {
    //    address[] memory currencies = new address[](1);
    //    currencies[0] = WETH;
    //    (limitedToken, quotaToken) = _createLimitedToken(name, symbol, metadata_, 18, 1_000_000_000e18, address(this), currencies);
    //    (,,, pair) = createLiquidity0ETH(limitedToken, 1_000_000_000e18, 50 ether);
    //    creator[limitedToken] = msg.sender;
    //    buyback[limitedToken] = limitedToken;
    //    launchPoolOf[limitedToken] = 
    //    pool = LiquidityLib.newLaunchPool(WETH, limitedToken, quotaToken, duration, begin_);
    //    quotaToken.safeTransferFrom(limitedToken, pool, 1_000_000_000e18 / 2);
    //    _notifyQuotaBegin(limitedToken, WETH, 2, 1 hours, duration, begin_);
    //    emit QuotaPoolCreated(name, symbol, begin_, limitedToken, quotaToken, pair, pool);
    //}
        
    function _createLimitedToken(string memory name_, string memory symbol_, string memory metadata_, uint8 decimals_, uint totalSupply_, address to, address[] memory currencies) internal returns (address limitedToken, address quotaToken) {
        (limitedToken, quotaToken) = NewLib.newLimitedERC20(name_, symbol_, decimals_, totalSupply_, to, currencies);
        quotaTokenOf[limitedToken] = quotaToken;
        metadata[limitedToken] = metadata_; 
        allLimitedTokens.push(limitedToken);
    }

    function checkbuyback(address buyback_) internal view returns (address) {
        require(quotaTokenOf[buyback_] != address(0), "buyback_!=LimitedERC20");
        return buyback_;
    }

    function setDuration_(uint duration_) external onlySetter {
        duration = duration_;
    }

    function setTaxRatio_(uint creatorRatio_, uint buybackRatio_) external onlySetter {
        creatorRatio = creatorRatio_;
        buybackRatio = buybackRatio_;
    }

    function _notifyQuotaBegin(address limitedToken, address taxToken, uint _lep, uint _period, uint _span, uint _begin) internal {
        lep[limitedToken][taxToken]             = _lep;         // 1: linear, 2: exponential, 3: power
        period[limitedToken][taxToken]          = _period;
        quotasDuration[limitedToken][taxToken]  = _span;
        begin[limitedToken][taxToken]           = _begin;
        periodFinish[limitedToken][taxToken]    = _begin.add(_span);
        quotasBuffer[limitedToken][taxToken]    = quotaSupply(limitedToken).mul(_period).div(_span);
        lastUpdateTime[limitedToken][taxToken]  = _begin;
    }

    function notifyQuotaBegin_(address limitedToken, address taxToken, uint _lep, uint _period, uint _span, uint _begin) external onlySetter {
        _notifyQuotaBegin(limitedToken, taxToken, _lep, _period, _span, _begin);
    }
    
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        super._swap(amounts, path, _to);
        for(uint i=0; i<amounts.length-1; i++)
            _swapFarming(path[i], amounts[i], path[i+1], amounts[i+1]);
    }
    
    function _swapFarming(address input, uint amountIn, address output, uint amountOut) internal {
        (uint feeRate, uint taxRate, address taxToken, ) = IUniswapV2Factory(factory).getTaxTo(input, output);
        uint rate = feeRate.mul(taxRate) / 1e18;
        if(input == taxToken)
            _swapFarming(buyback[output], input, amountIn, rate);
        else if(output == taxToken)
            _swapFarming(buyback[input], output, amountOut, rate);
    }

    function _swapFarming(address limitedToken, address taxToken, uint amount, uint rate) internal {
        address quotaToken = quotaTokenOf[limitedToken];
        if(msg.sender == limitedToken || limitedToken == address(0) || quotaToken == address(0) 
        || begin[limitedToken][taxToken] == 0 || begin[limitedToken][taxToken] >= now || lastUpdateTime[limitedToken][taxToken] >= now)
            return;
        uint quota;    uint tax;
        (quota, quotasBuffer[limitedToken][taxToken], taxsBuffer[limitedToken][taxToken], tax) = _swapFarmingable(limitedToken, taxToken, amount, rate);

        quotas[address(0)][limitedToken][address(0)] = quotas[address(0)][limitedToken][address(0)].add(quota);
        quotas[msg.sender][limitedToken][taxToken] = quotas[msg.sender][limitedToken][taxToken].add(quota);
        
        swapAmounts[msg.sender][limitedToken][taxToken] = swapAmounts[msg.sender][limitedToken][taxToken].add(amount);
        swapAmounts[address(0)][limitedToken][taxToken] = swapAmounts[address(0)][limitedToken][taxToken].add(amount);
        swapTaxs[msg.sender][limitedToken][taxToken] = swapTaxs[msg.sender][limitedToken][taxToken].add(tax);
        swapTaxs[address(0)][limitedToken][taxToken] = swapTaxs[address(0)][limitedToken][taxToken].add(tax);
        lastUpdateTime[limitedToken][taxToken] = now;
        emit SwapFarming(msg.sender, taxToken, amount, tax, quota);
    }
    event SwapFarming(address sender, address taxToken, uint amount, uint tax, uint quota);
    
    function _swapFarmingable(address limitedToken, address taxToken, uint amount, uint rate) internal view returns (uint quota, uint qtsBuf, uint taxsBuf, uint tax) {
        if(begin[limitedToken][taxToken] == 0 || begin[limitedToken][taxToken] >= now || lastUpdateTime[limitedToken][taxToken] >= now)
            return (0, 0, 0, 0);
        tax = amount.mul(rate).div(1e18);
        
        if(now < begin[limitedToken][taxToken].add(period[limitedToken][taxToken])) {
            taxsBuf = taxsBuffer[limitedToken][taxToken].mul(lastUpdateTime[limitedToken][taxToken].sub(begin[limitedToken][taxToken]));
            taxsBuf = taxsBuf.div(period[limitedToken][taxToken]).add(tax);
            taxsBuf = taxsBuf.mul(period[limitedToken][taxToken].add(now).sub(lastUpdateTime[limitedToken][taxToken]));
            taxsBuf = taxsBuf.div(now.sub(begin[limitedToken][taxToken]));
        } else
            taxsBuf = taxsBuffer[limitedToken][taxToken].add(tax);
        qtsBuf = quotasBuffer[limitedToken][taxToken].add(quotaDelta(limitedToken, taxToken));
        quota = qtsBuf.mul(tax).div(taxsBuf);
        taxsBuf = taxsBuf.mul(period[limitedToken][taxToken]).div(period[limitedToken][taxToken].add(now).sub(lastUpdateTime[limitedToken][taxToken]));
        qtsBuf = qtsBuf.sub(quota);
    }
    
    function swapFarmingable(address limitedToken, address taxToken, uint amount) external view returns (uint quota) {
        (quota, , , ) = _swapFarmingable(limitedToken, taxToken, amount, 0.01 ether);
    }
    
    //function swapFarmingablePath(uint amountIn, address[] calldata path) external view returns (address[] memory quotaTokens, uint[] memory qts) {
    //    uint[] memory amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
    //    quotaTokens = new address[](path.length.sub(1));
    //    qts        = new uint[]   (path.length.sub(1));
    //    for(uint i=0; i<amounts.length-1; i++) {
    //        (uint feeRate, uint taxRate, address taxToken, ) = LaunchSwapFactory(factory).getTaxTo(path[i], path[i+1]);
    //        uint rate = feeRate.mul(taxRate) / 1e18;
    //        if(path[i] == taxToken) {
    //            quotaTokens[i] = quotaTokenOf[path[i+1]];
    //            (qts[i], , , ) = _swapFarmingable(path[i+1], path[i], amounts[i], rate);
    //        } else if(path[i+1] == taxToken) {
    //            quotaTokens[i] = quotaTokenOf[path[i]];
    //            (qts[i], , , ) = _swapFarmingable(path[i], path[i+1], amounts[i+1], rate);
    //        }
    //    }
    //}
    
    function quotaSupply(address limitedToken) public view returns (uint) {
        return IERC20(quotaTokenOf[limitedToken]).balanceOf(limitedToken).sub0(quotas[address(0)][limitedToken][address(0)]);
    }
    
    function quotaDelta(address limitedToken, address taxToken) public view returns (uint amt) {
        if(begin[limitedToken][taxToken] == 0 || begin[limitedToken][taxToken] >= now || lastUpdateTime[limitedToken][taxToken] >= now)
            return 0;
            
        amt = quotaSupply(limitedToken);
        
        // calc quotaDelta in period
        //if(lep[limitedToken][taxToken] == 3) {                                                              // power
        //    uint amt2 = amt.mul(lastUpdateTime[limitedToken][taxToken].add(quotasDuration[limitedToken][taxToken]).sub(begin[limitedToken][taxToken])).div(now.add(quotasDuration[limitedToken][taxToken]).sub(begin[limitedToken][taxToken]));
        //    amt = amt.sub(amt2);
        //} else if(lep[limitedToken][taxToken] == 2) {                                                       // exponential
            if(now.sub(lastUpdateTime[limitedToken][taxToken]) < quotasDuration[limitedToken][taxToken])
                amt = amt.mul(now.sub(lastUpdateTime[limitedToken][taxToken])).div(quotasDuration[limitedToken][taxToken]);
        //}else if(now < periodFinish[limitedToken][taxToken])                                                // linear
        //    amt = amt.mul(now.sub(lastUpdateTime[limitedToken][taxToken])).div(periodFinish[limitedToken][taxToken].sub(lastUpdateTime[limitedToken][taxToken]));
        //else if(lastUpdateTime[limitedToken][taxToken] >= periodFinish[limitedToken][taxToken])
        //    amt = 0;
    }
    
    function claimable(address account, address limitedToken, address taxToken) public view returns (uint) {
        return quotas[account][limitedToken][taxToken];
    }

    function claim(address limitedToken, address taxToken) public {
        claimA(msg.sender, limitedToken, taxToken);
    }
    function claimA(address payable acct, address limitedToken, address taxToken) public {
        uint quota = quotas[acct][limitedToken][taxToken];
        if (quota > 0) {
            quotas[acct][limitedToken][taxToken] = 0;
            quotas[address(0)][limitedToken][address(0)] = quotas[address(0)][limitedToken][address(0)].sub0(quota);
            paid[acct][limitedToken][taxToken] = paid[acct][limitedToken][taxToken].add(quota);
            paid[address(0)][limitedToken][taxToken] = paid[address(0)][limitedToken][taxToken].add(quota);
            quotaTokenOf[limitedToken].safeTransferFrom(limitedToken, acct, quota);
            emit Claimed(acct, taxToken, quota);
        }
    }
    event Claimed(address indexed user, address taxToken, uint256 quota);

    //function claimAs(address payable acct, address[] calldata limitedTokens, address[] calldata taxTokens) external {
    //    for(uint i=0; i<taxTokens.length; i++)
    //        claimA(acct, limitedTokens[i], taxTokens[i]);
    //}
    
    function uniswapV2Call(address token, uint taxToken, uint amountTax, bytes calldata data) external {
        data;
        require(msg.sender == UniswapV2Library.pairFor(factory, token, address(taxToken))
            || msg.sender == launchPoolOf[token], "Illegal sender");
        uint amountCreator = 0;
        if(creator[token] != address(0)) {
            amountCreator = amountTax.mul(creatorRatio).div(1 ether);
            address(taxToken).safeTransfer(creator[token], amountCreator);
        }
        uint amountBuyback = 0;
        if(buyback[token] != address(0) && buyback[token] != LA) {
            amountBuyback = amountTax.mul(buybackRatio).div(1 ether);
            address(taxToken).safeTransfer(buyback[token], amountBuyback);
        }
        address(taxToken).safeTransfer(LA, amountTax.sub(amountCreator).sub(amountBuyback));
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[50] private ______gap;
}



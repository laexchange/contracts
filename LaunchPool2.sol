pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IUniswapV2Callee.sol';
import './libraries/SafeMath.sol';
import './libraries/TransferHelper.sol';

contract ConstSepolia {
    address internal constant oracleETH = 0x694AA1769357215DE4FAC081bf1f309aDC325306;      // Sepolia  ETH/USD chain.link data feeds
    address internal constant WETH      = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant USDT      = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;
    address internal constant USDC	    = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant USDX		= 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;
    IUniswapV2Router01 internal constant uniRouter = IUniswapV2Router01(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3);
}

contract ConstEthereum {
    address internal constant oracleETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;      // Ethereum ETH/USD chain.link data feeds
    address internal constant WETH      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT      = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDC	    = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDX		= 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
    IUniswapV2Router01 internal constant uniRouter = IUniswapV2Router01(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
}

contract LaunchPool2 is ConstSepolia {
    using SafeMath for uint;
    using TransferHelper for address;

    uint internal constant denominator = 1e36;
    uint internal constant timeslot = 5 minutes;
    address internal constant allAddr = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    IUniswapV2Router01 internal router;
    address[] public currencies;
    mapping (address => bool) public isCurrency;
    address public underlying;
    address public quotaToken;
    uint public duration;               // 20 days for quota = 5% remain
    uint public slippage;
    uint public withdrawTaxRate;
    uint public withdrawTaxSpan;
    mapping (address => mapping(address => uint)) public lasttimeDepositOf;     // owner => currency => 
    mapping (address => mapping(address => uint)) public underlyingPerTokenOf;  // owner => currency => 
    mapping (address => mapping(address => uint)) public balanceOf;             // owner => currency => 
    mapping (address => uint) public underlyingLastOf;                  // owner => 
    mapping (address => uint) public totalSupply;               // currency =>
    mapping (address => uint) public underlyingPerTokenLast;    // currency =>
    mapping (address => uint) public totalCurrencyLast;         // currency =>  == currency.balanceOf(address(this))
    mapping (address => uint) public lasttime;                  // currency =>  set lasttime to begin

    //constructor(address underlying_, address quotaToken_, uint duration_, uint begin) public {
    //    __LaunchPool2_init(underlying_, quotaToken_, duration_, begin);
    //}

    //function fix_() onlySetter external {
    //    underlyingLastOf[0xE2e5A0D2746D9B5Aa8c198b1FBe07bc3bB852775] = IERC20(underlying).balanceOf(address(this));
    //}

    function __LaunchPool2_init(address underlying_, address quotaToken_, uint duration_, uint begin) public {
        require(address(router) == address(0), "initialized");
        router = IUniswapV2Router01(msg.sender);
        underlying = underlying_;
        quotaToken = quotaToken_;
        duration   = duration_;
        slippage        = 0.01  ether;      // 1.0%
        withdrawTaxRate = 0.001 ether;      // 0.1%
        withdrawTaxSpan = 7 days;
        IERC20(quotaToken).approve(underlying_, uint(-1));
        currencies.push(WETH);
        currencies.push(USDT);
        currencies.push(USDC);
        currencies.push(USDX);
        for(uint i=0; i<currencies.length; i++) {
            address currency = currencies[i];
            IERC20(currency).approve(i==0 ? msg.sender : address(uniRouter), uint(-1));
            isCurrency[currency] = true;
            lasttime[currency] = _align(begin);
        }
    }
    
    function _align(uint time) internal pure returns (uint) {
        return time / timeslot * timeslot;
    }

    modifier onlySetter() {
        require(router.isSetter(msg.sender), "FORBIDDEN");
        _;
    }
    
    function setTime_(uint duration_, uint begin) onlySetter external {
        duration = duration_;
        for(uint i=0; i<currencies.length; i++)
            lasttime[currencies[i]] = _align(begin);
    }

    function setSlippage_(uint slippage_) onlySetter external {
        slippage = slippage_;
    }

    function setWithdrawTax_(uint taxRate, uint taxSpan) onlySetter external {
        require(taxRate <= 0.01 ether, "taxRate exceed 1%");
        withdrawTaxRate = taxRate;
        withdrawTaxSpan = taxSpan == 0 ? 100*365 days : taxSpan;
    }
    
    function deposit(address currency, uint value) external payable checkCurrency(currency) invest(msg.sender, currency) {
        uint amount;
        if(totalSupply[currency] == 0)
            amount = value;
        else if(totalCurrencyLast[currency] == 0) {        // Finished
            if(msg.value > 0)
                msg.sender.transfer(msg.value);
            return;
        } else
            amount = value.mul(totalSupply[currency]).div(totalCurrencyLast[currency]);
        if(msg.value >= value && currency == router.WETH())
            IWETH(currency).deposit.value(msg.value)();
        else
            currency.safeTransferFrom(msg.sender, address(this), value);
        balanceOf[msg.sender][currency] = balanceOf[msg.sender][currency].add(amount);
        totalSupply[currency] = totalSupply[currency].add(amount);
        totalCurrencyLast[currency]  = totalCurrencyLast[currency].add(value);
        lasttimeDepositOf[msg.sender][currency] = now;
        emit Transfer(address(0), msg.sender, currency, amount);
        emit Deposited(msg.sender, currency, value);
    }
    event Deposited(address indexed account, address indexed currency, uint value);
    event Transfer(address indexed from, address indexed to, address indexed currency, uint value);

    function withdraw(address currency, uint value) public checkCurrency(currency) invest(msg.sender, currency) returns (uint, uint) {
        uint amount = value.mul(totalSupply[currency]).div1(totalCurrencyLast[currency]);
        if(amount > balanceOf[msg.sender][currency]) {
            amount = balanceOf[msg.sender][currency];
            value = currencyOf(msg.sender, currency);
        }
        balanceOf[msg.sender][currency] = balanceOf[msg.sender][currency].sub(amount);
        totalSupply[currency] = totalSupply[currency].sub(amount);
        emit Transfer(msg.sender, address(0), currency, amount);
        totalCurrencyLast[currency]  = totalCurrencyLast[currency].sub(value);

        uint tax = lasttimeDepositOf[msg.sender][currency].add(withdrawTaxSpan) <= now ? 0 : value.mul(withdrawTaxRate).div(1 ether);
        currency.safeTransfer(address(router), tax);
        IUniswapV2Callee(address(router)).uniswapV2Call(underlying, uint(currency), tax, "");
        value = value.sub(tax);

        if(currency == router.WETH()) {
            IWETH(currency).withdraw(value);
            msg.sender.transfer(value);
        } else
            currency.safeTransfer(msg.sender, value);
        emit Withdrawn(msg.sender, currency, value, tax);
        return (value, tax);
    }
    event Withdrawn(address indexed account, address indexed currency, uint value, uint tax);

    function claim() public invest(msg.sender, allAddr) returns (uint volume) {
        volume = underlyingLastOf[msg.sender];
        underlyingLastOf[msg.sender] = 0;
        underlying.safeTransfer(msg.sender, volume);
        emit Claimed(msg.sender, volume);
    }
    event Claimed(address indexed account, uint volume);

    function exit() external returns (uint[] memory amts, uint[] memory taxs, uint vol) {
        uint N = currencies.length;
        amts = new uint[](N);
        taxs = new uint[](N);
        for(uint i=0; i<N; i++) {
            address currency = currencies[i];
            if(balanceOf[msg.sender][currency] > 0)
                (amts[i], taxs[i]) = withdraw(currency, balanceOf[msg.sender][currency]);
        }
        vol = claim();
    }

    function _checkCurrency(address currency) internal view {
        require(isCurrency[currency], "not currency");
    }
    
    modifier checkCurrency(address currency) {
        _checkCurrency(currency);
        _;
    }

    modifier invest(address account, address currency) {
        _invest(account, currency);
        _;
    }

    function _invest(address account, address currency) internal {
        if(currency == allAddr) {
            for(uint i=0; i<currencies.length; i++) {
                currency = currencies[i];
                if(balanceOf[msg.sender][currency] > 0)
                    _invest(account, currency);
            }
            return;
        }
        (uint quota, uint value, address[] memory path0Und, address[] memory pathCur0) = quotaDelta(currency);
        if(value > 0) {
            if(currency != currencies[0]) {
                require(currencies[0] == WETH && (currency == USDT || currency == USDC || currency == USDX), "Not desired currencies");
                uint desired = value.mul(currency == USDX ? 1e8 : 1e18/1e6*1e8).div(uint(AggregatorInterface(oracleETH).latestAnswer()));
                uint amount = uniRouter.swapExactTokensForTokens(value, 0, pathCur0, address(this), now)[1];
                require(amount.mul(1e18) >= desired.mul(uint(1e18).sub0(slippage)), "Slippage");
                quota = router.swapExactTokensForTokens(amount, 0, path0Und, address(this), now)[1];
            } else
                quota = router.swapExactTokensForTokens(value, 0, path0Und, address(this), now)[1];
            totalCurrencyLast[currency] = totalCurrencyLast[currency].sub(value);
            underlyingPerTokenLast[currency] = underlyingPerTokenLast[currency].add(quota.mul(denominator).div1(totalSupply[currency]));
        }
        lasttime[currency] = _align(now);
        if(account != address(0)) {
            underlyingLastOf[account] = underlyingOf(account, currency);
            underlyingPerTokenOf[account][currency] = underlyingPerTokenLast[currency];
        }
    }

    function calcTVL(address currency) public view returns(uint currV, uint TVL) {
        for(uint i=0; i<currencies.length; i++) {
            address curr = currencies[i];
            uint v;
            if(curr == USDX)
                v = totalCurrencyLast[curr];
            else if(curr == USDT || curr == USDC)
                v = totalCurrencyLast[curr].mul(1e18/1e6);
            else if(curr == WETH)
                v = totalCurrencyLast[curr].mul(uint(AggregatorInterface(oracleETH).latestAnswer())).div(1e8);
            TVL = TVL.add(v);
            if(curr == currency)
                currV = v;
        }
    }
    
    function quotaDelta(address currency) public view returns(uint quota, uint value, address[] memory path0Und, address[] memory pathCur0) {
        if(lasttime[currency] == 0 || lasttime[currency] >= _align(now) || totalCurrencyLast[currency] == 0)    // not init, not begin, finished    
            return(0, 0, path0Und, pathCur0);
        (uint currV, uint TVL) = calcTVL(currency);
        if(currV == 0 || TVL == 0)
            return(0, 0, path0Und, pathCur0);
        quota = IERC20(quotaToken).balanceOf(address(this)).mul(currV).div(TVL).mul(_align(now).sub(lasttime[currency])).div(duration);
        path0Und = new address[](2);                        pathCur0 = new address[](2);
        path0Und[0] = currencies[0];                        pathCur0[0] = currency;
        path0Und[1] = underlying;                           pathCur0[1] = currencies[0];
        value = router.getAmountsIn(quota, path0Und)[0];
        if(currency != currencies[0])
            value = uniRouter.getAmountsIn(value, pathCur0)[0];
        if(value >= totalCurrencyLast[currency]) {
            value = totalCurrencyLast[currency];
            quota = router.getAmountsOut(currency == currencies[0] ? value : uniRouter.getAmountsOut(value, pathCur0)[1], path0Und)[1];
        }
    }

    function underlyingPerToken(address currency) public view returns (uint) {
        (uint quota,,,) = quotaDelta(currency);
        return underlyingPerTokenLast[currency].add(quota.mul(denominator).div1(totalSupply[currency]));
    }

    function underlyingOf(address account, address currency) public view returns (uint) {
        return balanceOf[account][currency].mul(underlyingPerToken(currency).sub(underlyingPerTokenOf[account][currency])).div(denominator).add(underlyingLastOf[account]);
    }

    function currencyOf(address account, address currency) public view returns (uint) {
        return(balanceOf[account][currency].mul(totalCurrency(currency)).div1(totalSupply[currency]));
    }
    
    function totalCurrency(address currency) public view returns (uint) {
        (,uint value,,) = quotaDelta(currency);
        return totalCurrencyLast[currency].sub(value);
    }

    //function name() external view returns (string memory) {
    //    return string(abi.encodePacked("LaunchPool2 with for ", IERC20(underlying).symbol()));
    //}
    //
    //function symbol() external view returns (string memory) {
    //    return string(abi.encodePacked("la", IERC20(underlying).symbol()));
    //}

    function () external payable {           // receive
        require(msg.sender == router.WETH(), "WETH only");  // only accept ETH via fallback from the WETH contract
    }
}

interface AggregatorInterface {
  function latestAnswer() external view returns (int256);
  function latestTimestamp() external view returns (uint256);
  function latestRound() external view returns (uint256);
  function getAnswer(uint256 roundId) external view returns (int256);
  function getTimestamp(uint256 roundId) external view returns (uint256);

  event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
  event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
}

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);

  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

}



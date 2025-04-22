pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IUniswapV2Callee.sol';
import './libraries/SafeMath.sol';
import './libraries/TransferHelper.sol';


contract LaunchPool {
    using SafeMath for uint;
    using TransferHelper for address;

    uint internal constant denominator = 1e36;
    uint internal constant timeslot = 5 minutes;
    IUniswapV2Router01 internal router;
    address public currency;
    address public underlying;
    address public quotaToken;
    uint public duration;               // 20 days for quota = 5% remain
    uint public lasttime;               // set lasttime to begin
    uint public underlyingPerTokenLast;
    uint public totalCurrencyLast;      // == currency.balanceOf(address(this))
    uint public totalSupply;
    mapping (address => uint) public balanceOf;
    mapping (address => uint) public underlyingLastOf;
    mapping (address => uint) public underlyingPerTokenOf;
    uint public withdrawTaxRate;
    uint public withdrawTaxSpan;
    mapping (address => uint) public lasttimeDepositOf;

    constructor(address currency_, address underlying_, address quotaToken_, uint duration_, uint begin) public {
        router = IUniswapV2Router01(msg.sender);
        currency = currency_;
        underlying = underlying_;
        quotaToken = quotaToken_;
        duration = duration_;
        lasttime = _align(begin);
        IERC20(currency).approve(msg.sender, uint(-1));
        IERC20(quotaToken).approve(underlying_, uint(-1));
        withdrawTaxRate = 0.001 ether;                          // 0.1%
        withdrawTaxSpan = 7 days;
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
        lasttime = _align(begin);
    }

    function setWithdrawTaxRate_(uint taxRate) onlySetter external {
        require(taxRate <= 0.01 ether, "taxRate exceed 1%");
        withdrawTaxRate = taxRate;
    }
    
    function deposit(uint value) external payable invest(msg.sender) {
        uint amount;
        if(totalSupply == 0)
            amount = value;
        else if(totalCurrencyLast == 0) {        // Finished
            if(msg.value > 0)
                msg.sender.transfer(msg.value);
            return;
        } else
            amount = value.mul(totalSupply).div(totalCurrencyLast);
        if(msg.value >= value && currency == router.WETH())
            IWETH(currency).deposit.value(msg.value)();
        else
            currency.safeTransferFrom(msg.sender, address(this), value);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(amount);
        totalSupply = totalSupply.add(amount);
        totalCurrencyLast  = totalCurrencyLast.add(value);
        lasttimeDepositOf[msg.sender] = now;
        emit Transfer(address(0), msg.sender, amount);
        emit Deposited(msg.sender, value);
    }
    event Deposited(address indexed account, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function withdraw(uint value) public invest(msg.sender) returns (uint, uint) {
        uint amount = value.mul(totalSupply).div1(totalCurrencyLast);
        if(amount > balanceOf[msg.sender]) {
            amount = balanceOf[msg.sender];
            value = currencyOf(msg.sender);
        }
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(amount);
        totalSupply = totalSupply.sub(amount);
        emit Transfer(msg.sender, address(0), amount);
        totalCurrencyLast  = totalCurrencyLast.sub(value);

        uint tax = lasttimeDepositOf[msg.sender].add(withdrawTaxSpan) <= now ? 0 : value.mul(withdrawTaxRate).div(1 ether);
        currency.safeTransfer(address(router), tax);
        IUniswapV2Callee(address(router)).uniswapV2Call(underlying, uint(currency), tax, "");
        value = value.sub(tax);

        if(currency == router.WETH()) {
            IWETH(currency).withdraw(value);
            msg.sender.transfer(value);
        } else
            currency.safeTransfer(msg.sender, value);
        emit Withdrawn(msg.sender, value, tax);
        return (value, tax);
    }
    event Withdrawn(address indexed account, uint value, uint tax);

    function claim() public invest(msg.sender) returns (uint volume) {
        volume = underlyingLastOf[msg.sender];
        underlyingLastOf[msg.sender] = 0;
        underlying.safeTransfer(msg.sender, volume);
        emit Claimed(msg.sender, volume);
    }
    event Claimed(address indexed account, uint volume);

    function exit() external returns (uint amt, uint tax, uint vol) {
        (amt, tax) = withdraw(balanceOf[msg.sender]);
        vol = claim();
    }

    modifier invest(address account) {
        _invest(account);
        _;
    }

    function _invest(address account) internal {
        (uint quota, uint value, address[] memory path) = quotaDelta();
        if(value == 0) {
            if(value < totalCurrencyLast) {
                value = router.swapTokensForExactTokens(quota, totalCurrencyLast, path, address(this), now)[0];
            } else {
                quota = router.swapExactTokensForTokens(value, 0, path, address(this), now)[1];
            }
            totalCurrencyLast = totalCurrencyLast.sub(value);
            underlyingPerTokenLast = underlyingPerTokenLast.add(quota.mul(denominator).div1(totalSupply));
        }
        lasttime = _align(now);
        if(account != address(0)) {
            underlyingLastOf[account] = underlyingOf(account);
            underlyingPerTokenOf[account] = underlyingPerTokenLast;
        }
    }

    function quotaDelta() public view returns(uint quota, uint value, address[] memory path) {
        if(lasttime == 0 || lasttime >= _align(now) || totalCurrencyLast == 0)    // not init, not begin, finished    
            return(0, 0, path);
        path = new address[](2);
        path[0] = currency;
        path[1] = underlying;
        quota = IERC20(quotaToken).balanceOf(address(this)).mul(_align(now).sub(lasttime)).div(duration);
        value = router.getAmountsIn(quota, path)[0];
        if(value >= totalCurrencyLast) {
            value = totalCurrencyLast;
            quota = router.getAmountsOut(value, path)[1];
        }
    }

    function underlyingPerToken() public view returns (uint) {
        (uint quota,,) = quotaDelta();
        return underlyingPerTokenLast.add(quota.mul(denominator).div1(totalSupply));
    }

    function underlyingOf(address account) public view returns (uint) {
        return balanceOf[account].mul(underlyingPerToken().sub(underlyingPerTokenOf[account])).div(denominator).add(underlyingLastOf[account]);
    }

    function currencyOf(address account) public view returns (uint) {
        return(balanceOf[account].mul(totalCurrency()).div1(totalSupply));
    }
    
    function totalCurrency() public view returns (uint) {
        (,uint value,) = quotaDelta();
        return totalCurrencyLast.sub(value);
    }

    function name() external view returns (string memory) {
        return string(abi.encodePacked("LaunchPool with ", IERC20(currency).symbol(), " for ", IERC20(underlying).symbol()));
    }

    function symbol() external view returns (string memory) {
        return string(abi.encodePacked("la", IERC20(currency).symbol(), "_", IERC20(underlying).symbol()));
    }

    function decimals() external view returns (uint8) {
        return IERC20(currency).decimals();
    }

    function () external payable {           // receive
        require(msg.sender == router.WETH(), "WETH only");  // only accept ETH via fallback from the WETH contract
    }
}


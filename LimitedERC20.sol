pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import './UniswapV2ERC20.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Router01.sol';
import './libraries/TransferHelper.sol';

contract LimitedERC20 is UniswapV2ERC20 {
    using TransferHelper for address;

    address internal router;
    address internal factory;
    address public quotaToken;
    mapping (address => bool) public isLimitedPair;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint totalSupply_, address to, address[] memory currencies, address quotaToken_) 
        UniswapV2ERC20(name_, symbol_, decimals_, totalSupply_, to)
        public 
    {
        router = msg.sender;
        factory = IUniswapV2Router01(msg.sender).factory();
        _modifyCurrencies(currencies, true);
        quotaToken = quotaToken_;
        IERC20(quotaToken_).approve(msg.sender, uint(-1));
    }

    function _modifyCurrencies(address[] memory currencies, bool isAdd) internal {
        for(uint i=0; i<currencies.length; i++) {
            address pair = IUniswapV2Factory(factory).pairFor(address(this), currencies[i]);
            isLimitedPair[pair] = isAdd;
            IERC20(currencies[i]).approve(router, isAdd ? uint(-1) : 0);
        }
    }

    function modifyCurrencies(address[] calldata currencies, bool isAdd) external onlySetter {
        _modifyCurrencies(currencies, isAdd);
    }
    
    modifier onlySetter() {
        require(IUniswapV2Factory(factory).isSetter(msg.sender), "FORBIDDEN");
        _;
    }

    modifier spendQuota(address from, uint value) {
        _spendQuota(from, value);
        _;
    }

    function _spendQuota(address to, uint value) internal {
        if(!isLimitedPair[msg.sender] || to == 0x000000000000000000000000000000000000dEaD)
            return;
        if(IERC20(quotaToken).balanceOf(tx.origin) >= value) {
            quotaToken.safeTransferFrom(tx.origin, address(this), value);
        } else if(IERC20(quotaToken).balanceOf(to) >= value) {
            quotaToken.safeTransferFrom(to, address(this), value);
        } else
            revert("quota is not enough");
    }
    
    function transfer(address to, uint value) public spendQuota(to, value) returns (bool) {
        return super.transfer(to, value);
    }

    function buybackThenBurn(address currency, uint value, uint minAmount, uint deadline) external onlySetter returns (uint amount) {
        address[] memory path = new address[](2);
        path[0] = currency;
        path[1] = address(this);
        amount = IUniswapV2Router01(router).swapExactTokensForTokens(value, minAmount, path, 0x000000000000000000000000000000000000dEaD, deadline)[1];
        emit BuybackThenBurn(currency, value, amount);
    }
    event BuybackThenBurn(address currency, uint value, uint amount);
}



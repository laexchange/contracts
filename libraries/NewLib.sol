pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import '../UniswapV2ERC20.sol';
import '../LimitedERC20.sol';

library NewLib {
    function newUniswapV2ERC20(string memory name, string memory symbol, uint8 decimals, uint totalSupply, address to) public returns (address token) {
        token = address(new UniswapV2ERC20(name, symbol, decimals, totalSupply, to));
        emit TokenCreated(name, symbol, decimals, totalSupply, to, token);
    }
    event TokenCreated(string name, string symbol, uint8 decimals, uint totalSupply, address to, address token);
    
    function newLimitedERC20(string calldata name, string calldata symbol, uint8 decimals, uint totalSupply, address to, address[] calldata currencies) external returns (address limitedToken, address quotaToken) {
        quotaToken = newUniswapV2ERC20(
            string(abi.encodePacked("quotaToken of ", symbol)),
            string(abi.encodePacked("q", symbol)),
            decimals,
            totalSupply,
            address(this)
        );
        limitedToken = address(new LimitedERC20(name, symbol, decimals, totalSupply, to, currencies, quotaToken));
        TransferHelper.safeTransfer(quotaToken, limitedToken, totalSupply);
        emit LimitedTokenCreated(name, symbol, decimals, totalSupply, to, limitedToken, quotaToken);
    }
    event LimitedTokenCreated(string name, string symbol, uint8 decimals, uint totalSupply, address indexed to, address limitedToken, address quotaToken);
}


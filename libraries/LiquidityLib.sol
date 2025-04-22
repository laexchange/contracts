pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import '../LaunchPool.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IWETH.sol';
import '../interfaces/IUniswapV2Factory.sol';
import './SafeMath.sol';
import './UniswapV2Library.sol';
import './TransferHelper.sol';

library LiquidityLib {
    using SafeMath for uint;

    function newLaunchPool(address currency, address underlying, address quotaToken, uint duration, uint begin) external returns (address) {
        return address(new LaunchPool(currency, underlying, quotaToken, duration, begin));
    }

    function createLiquidity0ETH(
        address factory,
        address token,
        address WETH,
        uint amountDesired,
        uint valueDesired
    ) external returns (uint amount, uint value, uint liquidity, address pair) { 
        uint vReserve = valueDesired.mul(amountDesired).div(IERC20(token).totalSupply());
        IUniswapV2Factory(factory).createPairVRR(token, WETH, vReserve, 0.01 ether, 1 ether);
        (amount, value) = (amountDesired, valueDesired.sub(vReserve));
        pair = UniswapV2Library.pairFor(factory, token, WETH);
        if(IERC20(token).balanceOf(address(this)) >= amount)
            TransferHelper.safeTransfer(token, pair, amount);
        else
            TransferHelper.safeTransferFrom(token, msg.sender, pair, amount);
        require(msg.value >= value, "UniswapV2Router: INSUFFICIENT_ETH_VALUE");
        IWETH(WETH).deposit.value(value)();                                     // IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, value));
        liquidity = IUniswapV2Pair(pair).mint(0x000000000000000000000000000000000000dEaD);
    }

    function createLiquidity0(
        address factory,
        address token,
        address currency,
        uint amountDesired,
        uint valueDesired
    ) external returns (uint amount, uint value, uint liquidity, address pair) {
        uint vReserve = valueDesired.mul(amountDesired).div(IERC20(token).totalSupply());
        IUniswapV2Factory(factory).createPairVRR(token, currency, vReserve, 0.01 ether, 1 ether);
        (amount, value) = (amountDesired, valueDesired.sub(vReserve));
        pair = UniswapV2Library.pairFor(factory, token, currency);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amount);
        TransferHelper.safeTransferFrom(currency, msg.sender, pair, value);
        liquidity = IUniswapV2Pair(pair).mint(0x000000000000000000000000000000000000dEaD);
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address factory,
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB) {                                                               // virtual 
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        (uint vrA, uint vrB) = UniswapV2Library.getVReserves(factory, tokenA, tokenB);
        if (reserveA == 0 || reserveB == 0) {
            require(amountADesired >= vrA && amountBDesired >= vrB, "UniswapV2Router: amountDesired should be more than vReserve");
            (amountA, amountB) = (amountADesired.sub(vrA), amountBDesired.sub(vrB));
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
            amountA = amountA.sub(vrA.mul(amountA).div(reserveA));
            amountB = amountB.sub(vrB.mul(amountB).div(reserveB));
            require(amountA >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
            require(amountB >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
        }
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    function addLiquidity(
        address factory,
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {                              // virtual override 
        (amountA, amountB) = _addLiquidity(factory, tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
    function addLiquidityETH(
        address factory,
        address token,
        address WETH,
        uint amountTokenDesired,
        uint amountETHDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {                // virtual override 
        (amountToken, amountETH) = _addLiquidity(
            factory,
            token,
            WETH,
            amountTokenDesired,
            amountETHDesired,
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        require(msg.value >= amountETH, "UniswapV2Router: INSUFFICIENT_ETH_VALUE");
        IWETH(WETH).deposit.value(amountETH)();                                     // IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address factory,
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {        // virtual override 
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
    }
    function removeLiquidityETH(
        address factory,
        address token,
        address WETH,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountToken, uint amountETH) {  // virtual override 
        (amountToken, amountETH) = removeLiquidity(
            factory,
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function permitLiquidity(address factory, address tokenA, address tokenB, uint liquidity, uint deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s) external {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    }
}

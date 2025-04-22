pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Router01.sol';
import './upgradeable/Initializable.sol';
import './libraries/TransferHelper.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './libraries/NewLib.sol';
import './libraries/LiquidityLib.sol';

contract LaunchSwapRouter02 is IUniswapV2Router01, Initializable {      //IUniswapV2Router02, 
    using SafeMath for uint;

    address public factory;   // immutable override
    address public WETH;      // immutable override
    
    mapping (address => address) public creator;    // token =>
    mapping (address => address) public buyback;    // token =>
    address[] public allTokens;
    mapping (address => string) public metadata;    // token =>

    function allTokensLength() external view returns (uint) {
        return allTokens.length;
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlySetter() {
        require(isSetter(msg.sender), "FORBIDDEN");
        _;
    }

    function isSetter(address sender) public view returns (bool) {
        return IUniswapV2Factory(factory).isSetter(sender);
    }

    //constructor(address _factory, address _WETH) public {
    //    __LaunchSwapRouter02_init(_factory, _WETH);
    //}
    
    function __LaunchSwapRouter02_init(address _factory, address _WETH) public initializer {
        factory = _factory;
        WETH = _WETH;
    }

    function () external payable {  // receive
        require(msg.sender == WETH, "WETH only");   // only accept ETH via fallback from the WETH contract
    }

    function checkbuyback(address buyback_) internal view returns (address) {
        buyback;
        require(buyback_ == address(0), "buyback!=NULL");
        return buyback_;
    }

    function createToken(string memory name_, string memory symbol_, string memory metadata_, uint8 decimals_, uint totalSupply_, address to) public returns (address token) {
        token = NewLib.newUniswapV2ERC20(name_, symbol_, decimals_, totalSupply_, to);
        allTokens.push(token);
        metadata[token] = metadata_;
    }

    function createTokenAndLiquidity0ETH(string calldata name, string calldata symbol, string calldata metadata_, address buyback_) external payable returns (address token, address pair, uint amount) {
        token = createToken(name, symbol, metadata_, 18, 1_000_000_000e18, address(this));
        (,,, pair) = LiquidityLib.createLiquidity0ETH(factory, token, WETH, 1_000_000_000e18, 5 ether);
        creator[token] = msg.sender;
        buyback[token] = checkbuyback(buyback_);
        if(msg.value > 0) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = token;
            amount = swapExactETHForTokens(0, path, msg.sender, now)[1];
        }
        emit TokenAndLiquidity0ETHCreated(name, symbol, token, pair, msg.value, amount);
    }
    event TokenAndLiquidity0ETHCreated(string name, string symbol, address token, address pair, uint value, uint amount);
    
    function createLiquidity0ETH(
        address token,
        uint amountDesired,
        uint valueDesired
    ) public payable returns (uint amount, uint value, uint liquidity, address pair) {
        (amount, value, liquidity, pair) = LiquidityLib.createLiquidity0ETH(factory, token, WETH, amountDesired, valueDesired);
        // refund dust eth, if any
        if (msg.value > value) TransferHelper.safeTransferETH(msg.sender, msg.value - value);
    }

    function createLiquidity0(
        address token,
        address currency,
        uint amountDesired,
        uint valueDesired
    ) external returns (uint amount, uint value, uint liquidity, address pair) {
        return LiquidityLib.createLiquidity0(factory, token, currency, amountDesired, valueDesired);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity) {
        return LiquidityLib.addLiquidity(factory, tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);
    }
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountETHDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        return LiquidityLib.addLiquidityETH(
            factory, 
            token,
            WETH,
            amountTokenDesired,
            amountETHDesired,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public returns (uint amountA, uint amountB) {
        return LiquidityLib.removeLiquidity(factory, tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountToken, uint amountETH) {
        return LiquidityLib.removeLiquidityETH(factory, token, WETH, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB) {
        LiquidityLib.permitLiquidity(factory, tokenA, tokenB, liquidity, deadline, approveMax, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH) {
        LiquidityLib.permitLiquidity(factory, token, WETH, liquidity, deadline, approveMax, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    //function removeLiquidityETHSupportingFeeOnTransferTokens(
    //    address token,
    //    uint liquidity,
    //    uint amountTokenMin,
    //    uint amountETHMin,
    //    address to,
    //    uint deadline
    //) public ensure(deadline) returns (uint amountETH) {
    //    (, amountETH) = removeLiquidity(
    //        token,
    //        WETH,
    //        liquidity,
    //        amountTokenMin,
    //        amountETHMin,
    //        address(this),
    //        deadline
    //    );
    //    TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
    //    IWETH(WETH).withdraw(amountETH);
    //    TransferHelper.safeTransferETH(to, amountETH);
    //}
    //function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
    //    address token,
    //    uint liquidity,
    //    uint amountTokenMin,
    //    uint amountETHMin,
    //    address to,
    //    uint deadline,
    //    bool approveMax, uint8 v, bytes32 r, bytes32 s
    //) external returns (uint amountETH) { 
    //    address pair = UniswapV2Library.pairFor(factory, token, WETH);
    //    uint value = approveMax ? uint(-1) : liquidity;
    //    IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    //    amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
    //        token, liquidity, amountTokenMin, amountETHMin, to, deadline
    //    );
    //}

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {    // virtual 
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {           // virtual override 
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Slippage");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint[] memory amounts) {           // virtual override 
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "Slippage");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapExactETHForTokens(uint amountOutMin, address[] memory path, address to, uint deadline)
        public
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, "INVALID_PATH");
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Slippage");
        IWETH(WETH).deposit.value(amounts[0])();                                   // IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, "INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "Slippage");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, "INVALID_PATH");
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Slippage");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, "INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "Slippage");
        IWETH(WETH).deposit.value(amounts[0])();                                       // IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    //function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal {      // virtual 
    //    for (uint i; i < path.length - 1; i++) {
    //        (address input, address output) = (path[i], path[i + 1]);
    //        (address token0,) = UniswapV2Library.sortTokens(input, output);
    //        IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
    //        uint amountInput;
    //        uint amountOutput;
    //        { // scope to avoid stack too deep errors
    //        (uint reserve0, uint reserve1,) = pair.getReserves();
    //        (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    //        amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
    //        //amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
    //        amountOutput = LaunchSwapFactory(factory).getAmountOut(amountInput, reserveInput, reserveOutput);
    //        }
    //        (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
    //        address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
    //        pair.swap(amount0Out, amount1Out, to, new bytes(0));
    //    }
    //}
    //function swapExactTokensForTokensSupportingFeeOnTransferTokens(
    //    uint amountIn,
    //    uint amountOutMin,
    //    address[] calldata path,
    //    address to,
    //    uint deadline
    //) external ensure(deadline) {                                               // virtual override                     
    //    TransferHelper.safeTransferFrom(
    //        path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
    //    );
    //    uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
    //    _swapSupportingFeeOnTransferTokens(path, to);
    //    require(
    //        IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
    //        "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
    //    );
    //}
    //function swapExactETHForTokensSupportingFeeOnTransferTokens(
    //    uint amountOutMin,
    //    address[] calldata path,
    //    address to,
    //    uint deadline
    //)
    //    external
    //    //virtual
    //    //override
    //    payable
    //    ensure(deadline)
    //{
    //    require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
    //    uint amountIn = msg.value;
    //    IWETH(WETH).deposit.value(amountIn)();                                         // IWETH(WETH).deposit{value: amountIn}();
    //    assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
    //    uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
    //    _swapSupportingFeeOnTransferTokens(path, to);
    //    require(
    //        IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
    //        "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
    //    );
    //}
    //function swapExactTokensForETHSupportingFeeOnTransferTokens(
    //    uint amountIn,
    //    uint amountOutMin,
    //    address[] calldata path,
    //    address to,
    //    uint deadline
    //)
    //    external
    //    //virtual
    //    //override
    //    ensure(deadline)
    //{
    //    require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
    //    TransferHelper.safeTransferFrom(
    //        path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
    //    );
    //    _swapSupportingFeeOnTransferTokens(path, address(this));
    //    uint amountOut = IERC20(WETH).balanceOf(address(this));
    //    require(amountOut >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
    //    IWETH(WETH).withdraw(amountOut);
    //    TransferHelper.safeTransferETH(to, amountOut);
    //}

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure returns (uint amountB) {     // virtual override 
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        view
        //virtual
        //override
        returns (uint amountOut)
    {
        //return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
        return IUniswapV2Factory(factory).getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        view
        //virtual
        //override
        returns (uint amountIn)
    {
        //return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
        return IUniswapV2Factory(factory).getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        //virtual
        //override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        //virtual
        //override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[50-4] private ______gap;
}


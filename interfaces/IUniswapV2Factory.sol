pragma solidity >=0.5.0;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function isSetter(address sender) external view returns (bool);

    function pairFor(address tokenA, address tokenB) external view returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function getPairFor(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);
    function createPairVR(address token, address currency, uint vReserve) external returns (address pair);
    function createPairVRR(address token, address currency, uint vReserve, uint _feeRate, uint _taxRate) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;

    function getTaxTo(address token0, address token1) external view returns (uint _feeRate, uint _taxRate, address _taxToken, address _taxTo);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external view returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external view returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}
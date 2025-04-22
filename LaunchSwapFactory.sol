pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './interfaces/IUniswapV2Factory.sol';
import './LaunchSwapPair.sol';
import './upgradeable/Proxy.sol';


contract LaunchSwapFactory is IUniswapV2Factory {
    using SafeMath for uint;
    
    bytes32 public constant pairCodeHash = keccak256(abi.encodePacked(type(InitializableProductProxy).creationCode));
    
    address public productImplementation;
    
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    
    mapping(address => uint) public feeRate;
    mapping(address => uint) public taxRate;
    mapping(address => uint) public taxPriority;
    mapping(address => address) public taxTo;

    uint public holdRateVR;

    function __LaunchSwapFactory_init(address _feeToSetter, address _productImplementation, address WETH, address router) public {
        require(feeToSetter== address(0) && _feeToSetter != address(0), "LaunchSwapFactory.__LaunchSwapFactory_init can be delegatecall once by proxy only.");
        feeToSetter = _feeToSetter;
        productImplementation = _productImplementation;
        feeRate[address(0)] = 0.01  ether;      //   1%         0.003 ether;      // 0.3%
        taxRate[address(0)] = 1.00  ether;      // 100%         0.30  ether;      // 30%
        holdRateVR          = 0.10  ether;      //  10%
        taxPriority[WETH]   = 100;
        feeTo               = router;
    }
    
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        return createPairVR(tokenA, tokenB, 0);
    }

    function createPairVR(address token, address currency, uint vReserve) public returns (address pair) {
        require(vReserve == 0 || Math.max(IERC20(token).balanceOf(msg.sender), IERC20(token).balanceOf(tx.origin)).mul(1 ether) >= IERC20(token).totalSupply().mul(holdRateVR), "holdRateVR");//"Only more than holdRateVR token holder can create pair with virtual reserve");
        require(token != currency, "IDENTICAL_ADDRESSES");
        (address token0, address token1, uint vr0, uint vr1) = token < currency ? (token, currency, uint(0), vReserve) : (currency, token, vReserve, uint(0));
        require(token0 != address(0), "ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "PAIR_EXISTS"); // single check is sufficient
        bytes memory bytecode = type(InitializableProductProxy).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        InitializableProductProxy(uint160(pair)).__InitializableProductProxy_init(address(this), 0x0, abi.encodeWithSignature('__LaunchSwapPair_init(address,address,uint256,uint256)', token0, token1, vr0, vr1));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
        emit PairCreatedVR(token, currency, vReserve, pair, allPairs.length);
    }
    event PairCreated(address indexed token0, address indexed token1, address pair, uint N);
    event PairCreatedVR(address indexed token, address indexed currency, uint vReserve, address pair, uint N);

    function createPairVRR(address token, address currency, uint vReserve, uint _feeRate, uint _taxRate) public returns (address pair) {
        require(_feeRate <= 1 ether && _taxRate <= 1 ether, "feeRate or taxRate exceed 100%");
        pair = createPairVR(token, currency, vReserve);
        feeRate[pair] = _feeRate;
        taxRate[pair] = _taxRate;
    }

    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _admin() internal view returns (address adm) {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            adm := sload(slot)
        }
    }
    
    modifier onlySetter() {
        require(isSetter(msg.sender), "FORBIDDEN");
        _;
    }
    
    function isSetter(address sender) public view returns (bool) {
        return sender == feeToSetter || sender == _admin();
    }

    function setProductImplementation(address _productImplementation) external onlySetter {
        productImplementation = _productImplementation;
    }

    function setHoldRateVR(uint _holdRateVR) external onlySetter {
        holdRateVR = _holdRateVR;
    }
    
    function setFeeTo(address _feeTo) external onlySetter {
        feeTo = _feeTo;
    }
    
    function setTaxTo(address _taxToken, address _taxTo, uint _taxPriority) external onlySetter {
        taxTo[_taxToken] = _taxTo;
        taxPriority[_taxToken] = _taxPriority;
    }
    
    function setFeeToSetter(address _feeToSetter) external onlySetter {
        feeToSetter = _feeToSetter;
    }
    
    function setFeeRate(address pair, uint _feeRate, uint _taxRate) external onlySetter {
        feeRate[pair] = _feeRate;
        taxRate[pair] = _taxRate;
    }
    
    function getFeeRate(address pair) public view returns (uint _feeRate, uint _taxRate) {
        _feeRate = feeRate[pair];
        if(_feeRate == 0)
            _feeRate= feeRate[address(0)];
        _taxRate = taxRate[pair];
        if(_taxRate == 0)
            _taxRate = taxRate[address(0)];
    }
    
    function getTaxTo(address token0, address token1) public view returns (uint _feeRate, uint _taxRate, address _taxToken, address _taxTo) {
        address pair = getPair[token0][token1];
        (_feeRate, _taxRate) = getFeeRate(pair);
        (uint priority0, uint priority1) = (taxPriority[token0], taxPriority[token1]);
        _taxToken = priority0 > priority1 ? token0 : priority0 < priority1 ? token1 : pair;
        _taxTo = taxTo[pair];
        if(_taxTo == address(0))
            _taxTo = taxTo[_taxToken];
        if(_taxTo == address(0))
            _taxTo = feeTo;
    }
    
    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "LaunchSwapFactory: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "LaunchSwapFactory: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex"ff",
                address(this),
                keccak256(abi.encodePacked(token0, token1)),
                pairCodeHash
            ))));
    }

    // return getPair if pair exist, or else return pairFor
    function getPairFor(address tokenA, address tokenB) public view returns (address pair) {
        pair = getPair[tokenA][tokenB];
        if(pair == address(0))
            pair = pairFor(tokenA, tokenB);
    }
    
    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB) public view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function getVReserves(address tokenA, address tokenB) public view returns (uint vrA, uint vrB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint vr0, uint vr1) = IUniswapV2Pair(pairFor(tokenA, tokenB)).getVReserves();
        (vrA, vrB) = tokenA == token0 ? (vr0, vr1) : (vr1, vr0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) public pure returns (uint amountB) {
        require(amountA > 0, "LaunchSwapFactory: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "LaunchSwapFactory: INSUFFICIENT_LIQUIDITY");
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOutPair(address pair, uint amountIn, uint reserveIn, uint reserveOut) public view returns (uint amountOut) {
        require(amountIn > 0, "LaunchSwapFactory: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "LaunchSwapFactory: INSUFFICIENT_LIQUIDITY");
        (uint _feeRate, ) = getFeeRate(pair);
        //uint amountInWithFee = amountIn.mul(997);
        uint amountInWithFee = amountIn.mul(uint(1e18).sub(_feeRate)) / 1e14;
        uint numerator = amountInWithFee.mul(reserveOut);
        //uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        uint denominator = reserveIn.mul(1e4).add(amountInWithFee);
        amountOut = numerator / denominator;
    }
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public view returns (uint amountOut) {
        return getAmountOutPair(address(0), amountIn, reserveIn, reserveOut);
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountInPair(address pair, uint amountOut, uint reserveIn, uint reserveOut) public view returns (uint amountIn) {
        require(amountOut > 0, "LaunchSwapFactory: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "LaunchSwapFactory: INSUFFICIENT_LIQUIDITY");
        (uint _feeRate, ) = getFeeRate(pair);
        //uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint numerator = reserveIn.mul(amountOut).mul(1e4);
        //uint denominator = reserveOut.sub(amountOut).mul(997);
        uint denominator = reserveOut.sub(amountOut).mul(uint(1e18).sub(_feeRate)) / 1e14;
        amountIn = (numerator / denominator).add(1);
    }
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public view returns (uint amountIn) {
        return getAmountInPair(address(0), amountOut, reserveIn, reserveOut);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, "LaunchSwapFactory: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOutPair(pairFor(path[i], path[i + 1]), amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, "LaunchSwapFactory: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i - 1], path[i]);
            amounts[i - 1] = getAmountInPair(pairFor(path[i - 1], path[i]), amounts[i], reserveIn, reserveOut);
        }
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[50-5] private ______gap;
}



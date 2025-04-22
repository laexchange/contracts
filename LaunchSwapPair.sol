pragma solidity =0.5.17;
pragma experimental ABIEncoderV2;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './upgradeable/Initializable.sol';
import './libraries/OpenZeppelinUpgradesAddress.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract LaunchSwapPair is IUniswapV2Pair, UniswapV2ERC20, Initializable {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //uint private unlocked = 1;
    //modifier lock() {
    //    require(unlocked == 1, "LOCKED");
    //    unlocked = 0;
    //    _;
    //    unlocked = 1;
    //}
    // compatibility for Upgradeable, as described in
    // https://docs.openzeppelin.com/upgrades/2.8/writing-upgradeable#avoid-initial-values-in-field-declarations
    uint private locked;
    modifier lock() {
        require(locked == 0, "LaunchSwap: LOCKED");
        locked = 1;
        _;
        locked = 0;
    }

    uint public vReserve0;
    uint public vReserve1;

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function getVReserves() public view returns (uint vr0, uint vr1) {
        vr0 = vReserve0;
        vr1 = vReserve1;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() UniswapV2ERC20("LaunchSwap Liquidity Provider Token", "LSLP", 18, 0, address(0)) public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function __LaunchSwapPair_init(address _token0, address _token1, uint _vReserve0, uint _vReserve1) external initializer {
        //require(msg.sender == factory, "FORBIDDEN"); // sufficient check
        if(factory == address(0)) {
            UniswapV2ERC20.__UniswapV2ERC20_init("LaunchSwap Liquidity Provider Token", "LSLP", 18, 0, 0x000000000000000000000000000000000000dEaD);
            factory = msg.sender;
        }
        token0 = _token0;
        token1 = _token1;
        require(_vReserve0 <= uint112(-1) && _vReserve1 <= uint112(-1), "OVERFLOW");
        (reserve0, reserve1) = (uint112(_vReserve0), uint112(_vReserve1));
        vReserve0 = _vReserve0;
        vReserve1 = _vReserve1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint vr0, uint vr1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0.add(vr0) <= uint112(-1) && balance1.add(vr1) <= uint112(-1), "OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0.add(vr0));
        reserve1 = uint112(balance1.add(vr1));
        blockTimestampLast = blockTimestamp;
        vReserve0 = vr0;
        vReserve1 = vr1;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        (, uint _taxRate, address _taxToken, address feeTo) = IUniswapV2Factory(factory).getTaxTo(token0, token1);
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            //if (_kLast != 0) {
            if (_kLast != 0 && _taxToken == address(this)) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    //uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint numerator = (totalSupply.mul(_taxRate) / 1e14).mul(rootK.sub(rootKLast));
                    //uint denominator = rootK.mul(5).add(rootKLast);
                    uint denominator = rootK.mul(uint(1e18).sub(_taxRate)).add(rootKLast.mul(_taxRate)) / 1e14;
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        (uint vr0, uint vr1) = (vReserve0, vReserve1); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.add(vr0).sub(_reserve0);
        uint amount1 = balance1.add(vr1).sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.add(vr0).mul(amount1.add(vr1))).sub(MINIMUM_LIQUIDITY);
           _mint(0x000000000000000000000000000000000000dEaD, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(_reserve0 <= vr0 ? uint(-1) : amount0.mul(_totalSupply) / uint(_reserve0).sub(vr0), _reserve1 <= vr1 ? uint(-1) : amount1.mul(_totalSupply) / uint(_reserve1).sub(vr1));
            vr0 = vr0.mul(_totalSupply.add(liquidity)).div(_totalSupply);
            vr1 = vr1.mul(_totalSupply.add(liquidity)).div(_totalSupply);
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, vr0, vr1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        (uint vr0, uint vr1) = (vReserve0, vReserve1);           // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        vr0 = vr0.mul(_totalSupply.sub(liquidity)).div(_totalSupply);
        vr1 = vr1.mul(_totalSupply.sub(liquidity)).div(_totalSupply);
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, vr0, vr1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out <= uint(_reserve0).sub(vReserve0) && amount1Out <= uint(_reserve1).sub(vReserve1), "INSUFFICIENT_LIQUIDITY");

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, "INVALID_TO");
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - vReserve0 - amount0Out ? balance0 - (_reserve0 - vReserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - vReserve1 - amount1Out ? balance1 - (_reserve1 - vReserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");
        { // scope for _feeRate, _taxRate, _taxToken, _taxTo avoids stack too deep errors
        (uint _feeRate, uint _taxRate, address _taxToken, address _taxTo) = IUniswapV2Factory(factory).getTaxTo(token0, token1);
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        //uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance0Adjusted = balance0.add(vReserve0).mul(1e18).sub(amount0In.mul(_feeRate)) / 1e14;     
        //uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        uint balance1Adjusted = balance1.add(vReserve1).mul(1e18).sub(amount1In.mul(_feeRate)) / 1e14;
        //require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), "UniswapV2: K");
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(uint(_reserve1).mul(1e8)), "K");
        }
        uint tax = _taxToken == token0 ? amount0In + amount0Out : _taxToken == token1 ? amount1In + amount1Out : 0;
        tax = (tax.mul(_feeRate) / 1e18).mul(_taxRate) / 1e18;
        _safeTransfer(_taxToken, _taxTo, tax);
        if(OpenZeppelinUpgradesAddress.isContract(_taxTo))
            IUniswapV2Callee(_taxTo).uniswapV2Call(address(uint(token0)^uint(token1)^uint(_taxToken)), uint(_taxToken), tax, "");
        if(_taxToken == token0)
            balance0 = balance0.sub(tax);
        else if(_taxToken == token1)
            balance1 = balance1.sub(tax);
        }

        _update(balance0, balance1, vReserve0, vReserve1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).add(vReserve0).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).add(vReserve1).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), vReserve0, vReserve1, reserve0, reserve1);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[48] private ______gap;
}



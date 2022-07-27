// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Clones} from "openzeppelin-contracts/proxy/Clones.sol";

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Gate} from "timeless/Gate.sol";
import {Factory} from "timeless/Factory.sol";
import {IxPYT} from "timeless/external/IxPYT.sol";
import {YearnGate} from "timeless/gates/YearnGate.sol";
import {TestXPYT} from "timeless/test/mocks/TestXPYT.sol";
import {TestERC20} from "timeless/test/mocks/TestERC20.sol";
import {TestERC4626} from "timeless/test/mocks/TestERC4626.sol";
import {NegativeYieldToken} from "timeless/NegativeYieldToken.sol";
import {PerpetualYieldToken} from "timeless/PerpetualYieldToken.sol";
import {TestYearnVault} from "timeless/test/mocks/TestYearnVault.sol";

import {Swapper} from "../Swapper.sol";
import {CurveDeployer} from "./utils/CurveDeployer.sol";
import {ICurveTokenV5} from "./external/ICurveTokenV5.sol";
import {CurveV2Juggler} from "../curve-v2/CurveV2Juggler.sol";
import {CurveV2Swapper} from "../curve-v2/CurveV2Swapper.sol";
import {ICurveCryptoSwap2ETH} from "../curve-v2/external/ICurveCryptoSwap2ETH.sol";

contract CurveV2SwapperTest is Test, CurveDeployer {
    using Clones for address;

    address constant recipient = address(0x42);
    address constant swapFeeRecipient = address(0x6969);
    address constant protocolFeeRecipient = address(0x69);

    uint8 constant PROTOCOL_FEE = 100; // 10%
    uint8 constant SWAPPER_PROTOCOL_FEE = 10; // 0.1%
    uint8 constant DECIMALS = 18;
    uint256 constant ONE = 10**DECIMALS;
    uint256 constant AMOUNT = 100 * ONE;
    uint256 constant MAX_ERROR = 1;

    Factory factory;
    Gate gate;
    TestERC20 underlying;
    address vault;
    NegativeYieldToken nyt;
    PerpetualYieldToken pyt;
    IxPYT xPYT;
    ICurveTokenV5 curveLP;
    ICurveCryptoSwap2ETH curvePool;
    Swapper swapper;
    CurveV2Juggler juggler;
    WETH weth;

    function setUp() public {
        // deploy weth
        weth = new WETH();

        // deploy factory
        factory = new Factory(
            Factory.ProtocolFeeInfo({
                fee: PROTOCOL_FEE,
                recipient: protocolFeeRecipient
            })
        );

        // deploy gate
        gate = new YearnGate(factory);

        // deploy underlying
        underlying = new TestERC20(DECIMALS);

        // deploy vault
        vault = address(new TestYearnVault(underlying));

        // deploy PYT & NYT
        (nyt, pyt) = factory.deployYieldTokenPair(gate, vault);

        // deploy xPYT
        xPYT = new TestXPYT(ERC20(address(pyt)));

        // deploy curve pool
        curveLP = ICurveTokenV5(deployCurveTokenV5().clone());
        curvePool = ICurveCryptoSwap2ETH(
            deployCurveCryptoSwap2ETH(weth).clone()
        );
        vm.label(address(curveLP), "CurveTokenV5");
        vm.label(address(curvePool), "CurveCryptoSwap2ETH");
        curveLP.initialize("Curve LP", "CRV-LP", curvePool);
        curvePool.initialize(
            400000,
            145000000000000,
            26000000,
            45000000,
            2000000000000,
            230000000000000,
            146000000000000,
            0,
            600,
            ONE,
            address(curveLP),
            [address(nyt), address(xPYT)],
            (18 - DECIMALS) + ((18 - DECIMALS) << 8)
        );

        // mint underlying
        underlying.mint(address(this), 3 * AMOUNT);

        // mint xPYT & NYT
        underlying.approve(address(gate), type(uint256).max);
        gate.enterWithUnderlying(
            address(this),
            address(this),
            vault,
            xPYT,
            2 * AMOUNT
        );

        // add liquidity
        nyt.approve(address(curvePool), type(uint256).max);
        xPYT.approve(address(curvePool), type(uint256).max);
        curvePool.add_liquidity([AMOUNT, AMOUNT], 0);

        // deploy swapper
        swapper = new CurveV2Swapper(
            address(0),
            weth,
            Swapper.ProtocolFeeInfo({
                fee: SWAPPER_PROTOCOL_FEE,
                recipient: swapFeeRecipient
            })
        );

        // deploy juggler
        juggler = new CurveV2Juggler();

        // set token approvals
        underlying.approve(address(swapper), type(uint256).max);
        nyt.approve(address(swapper), type(uint256).max);
        xPYT.approve(address(swapper), type(uint256).max);

        // token balances:
        // underlying: AMOUNT
        // xPYT: AMOUNT
        // NYT: AMOUNT
    }

    function testBasic_swapUnderlyingToNyt() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool)
        });
        uint256 tokenAmountOut = swapper.swapUnderlyingToNyt(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            underlying.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "underlying balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            nyt.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            underlying.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function testBasic_swapUnderlyingToXpyt() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool)
        });
        uint256 tokenAmountOut = swapper.swapUnderlyingToXpyt(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            underlying.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "underlying balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            underlying.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function testBasic_swapUnderlyingToPyt() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: true,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool)
        });
        uint256 tokenAmountOut = swapper.swapUnderlyingToXpyt(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            underlying.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "underlying balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            pyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero PYT"
        );
        assertEqDecimal(
            pyt.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            underlying.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function testBasic_swapNytToUnderlying() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        uint256 tokenAmountInAfterFee = tokenAmountIn -
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) /
            10000;
        uint256 swapAmountIn = juggler.juggleNytInput(
            xPYT,
            curvePool,
            tokenAmountInAfterFee,
            MAX_ERROR
        );
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool, swapAmountIn)
        });
        uint256 tokenAmountOut = swapper.swapNytToUnderlying(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            nyt.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "NYT balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            underlying.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            nyt.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function testBasic_swapXpytToUnderlying() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        uint256 tokenAmountInAfterFee = tokenAmountIn -
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) /
            10000;
        uint256 swapAmountIn = juggler.juggleXpytInput(
            xPYT,
            curvePool,
            tokenAmountInAfterFee,
            MAX_ERROR
        );
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool, swapAmountIn)
        });
        uint256 tokenAmountOut = swapper.swapXpytToUnderlying(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            xPYT.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "xPYT balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            underlying.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            xPYT.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function testBasic_swapPytToUnderlying() public {
        uint256 tokenAmountIn = xPYT.redeem(
            AMOUNT / 10,
            address(this),
            address(this)
        );
        uint256 tokenAmountInAfterFee = tokenAmountIn -
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) /
            10000;
        uint256 swapAmountIn = juggler.juggleXpytInput(
            xPYT,
            curvePool,
            tokenAmountInAfterFee,
            MAX_ERROR
        );
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            pyt: ERC20(address(pyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            usePYT: true,
            deadline: block.timestamp,
            extraArgs: abi.encode(curvePool, swapAmountIn)
        });
        pyt.approve(address(swapper), type(uint256).max);
        uint256 tokenAmountOut = swapper.swapXpytToUnderlying(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            pyt.balanceOf(address(this)),
            0,
            DECIMALS,
            "PYT balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            pyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero PYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            underlying.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
        assertEqDecimal(
            xPYT.balanceOf(swapFeeRecipient),
            (tokenAmountIn * SWAPPER_PROTOCOL_FEE) / 10000,
            DECIMALS,
            "swap fee recipient didn't get fee"
        );
    }

    function test_wrapEthInput() public {
        swapper.wrapEthInput{value: 1 ether}();
        assertEqDecimal(
            weth.balanceOf(address(swapper)),
            1 ether,
            18,
            "wrap ETH failed"
        );
    }
}

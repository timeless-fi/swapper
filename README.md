# Swapper

Enables swapping between an xPYT/NYT and its underlying asset by swapping via an external DEX and minting/burning xPYT/NYT.

## Architecture

-   [`Swapper.sol`](src/Swapper.sol): Abstract contract for swapping between xPYTs/NYTs and their underlying asset by swapping via an external DEX and minting/burning xPYT/NYT.
-   [`uniswap-v3/`](src/uniswap-v3/): Uniswap V3 support
    -   [`UniswapV3Swapper.sol`](src/uniswap-v3/UniswapV3Swapper.sol): Swapper that uses Uniswap V3 to swap between xPYTs/NYTs
    -   [`UniswapV3Juggler.sol`](src/uniswap-v3/UniswapV3Juggler.sol): Given xPYT/NYT input, computes how much to swap to result in an equal amount of PYT & NYT.
    -   [`lib/`](src/uniswap-v3/lib/): Libraries used
        -   [`PoolAddress.sol`](src/uniswap-v3/lib/PoolAddress.sol): Provides functions for deriving a Uniswap V3 pool address from the factory, tokens, and the fee
-   [`curve-v2/`](src/curve-v2/): Curve V2 support
    -   [`CurveV2Swapper.sol`](src/curve-v2/CurveV2Swapper.sol): Swapper that uses Curve V2 to swap between xPYTs/NYTs
    -   [`CurveV2Juggler.sol`](src/curve-v2/CurveV2Juggler.sol): Given xPYT/NYT input, computes how much to swap to result in an equal amount of PYT & NYT.
-   [`lib/`](src/lib/): Helpful libraries
    -   [`ApproveMaxIfNeeded.sol`](src/lib/ApproveMaxIfNeeded.sol): Gives max ERC20 approval to the spender if the current allowance is insufficient.

## Installation

To install with [DappTools](https://github.com/dapphub/dapptools):

```
dapp install timeless-fi/swapper
```

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install timeless-fi/swapper
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
make install
```

### Compilation

```
make build
```

### Testing

```
make test
```

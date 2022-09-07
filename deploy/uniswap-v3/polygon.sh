# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/polygon.json
export RPC_URL=$RPC_URL_POLYGON

# load common utilities
. $(dirname $0)/../common.sh

# deploy contracts
univ3_swapper_address=$(deployViaCast UniswapV3Swapper 'constructor(address,address,(uint8,address),address)' $ZEROEX_PROXY $WETH_POLYGON $PROTOCOL_FEE_POLYGON $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

send $univ3_swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_POLYGON true false
echo "UniswapV3SwapperOwner=$INITIAL_OWNER_POLYGON"

univ3_juggler_address=$(deployViaCast UniswapV3Juggler 'constructor(address,address)' $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"
# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/optimism.json
export RPC_URL=$RPC_URL_OPTIMISM

# load common utilities
. $(dirname $0)/../common.sh

# deploy contracts
univ3_swapper_address=$(deployViaCast UniswapV3Swapper 'constructor(address,address,(uint8,address),address)' $ZEROEX_PROXY_OPTIMISM $WETH_OPTIMISM $PROTOCOL_FEE_OPTIMISM $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

send $univ3_swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_OPTIMISM true false
echo "UniswapV3SwapperOwner=$INITIAL_OWNER_OPTIMISM"

univ3_juggler_address=$(deployViaCast UniswapV3Juggler 'constructor(address,address)' $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"
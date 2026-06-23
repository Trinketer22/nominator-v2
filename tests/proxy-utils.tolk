import "@contracts/types"
import "@wrappers/Proxy.gen"

fun getProxy(poolAddress: address, validator: address, isOdd: bool): Proxy {
    val proxy = Proxy.fromStorage(
        ProxyStorage {
            pool: poolAddress,
            validator,
            roundParity: isOdd,
        },
        null,
        -1,
    );

    return proxy;
}

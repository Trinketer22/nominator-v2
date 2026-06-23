import "@stdlib/reflection"

fun opcode<T>(): int {
    return reflect.serializationPrefixOf<T>().0;
}

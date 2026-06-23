import "@stdlib/reflection"
import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/messages"
import "@contracts/types"
import "@tests/elector-utils"
import "@wrappers/ElectorCode.gen"

get fun `test elector setup`() {
    val (elector, _stakes, _elections) = setupElector();
    clearNextValidators();
    val curElections = announceElections(elector);
    expect(curElections).toNotEqual(0);

    val validator = randomAddress("test validator", -1);
    val testValue = ton("1000000");

    testing.setChecksigIgnore(true);
    val newStake = createMessage({
        bounce: true,
        value: testValue + ton("1"),
        dest: elector.address,
        body: NewStakeDirect {
            queryId: 0x123,
            publicKey: random.uint256(),
            stakeAt: curElections,
            maxFactor: 294912,
            adnl: 0,
            signature: ValidatorSignature {
                signature: crypto
                    .getFastRandomBytes(64)
                    .toCell()
                    .beginParse()
                    .loadBits(512) as bits512,
            }.toCell(),
        },
    });

    val res = net.send(validator, newStake);
    val _stakeTx = res.findTransaction({ from: validator, to: elector.address })!;
    expect(res).toHaveTx({
        from: elector.address,
        to: validator,
        opcode: reflect.serializationPrefixOf<NewStakeOk>().0,
    });
}

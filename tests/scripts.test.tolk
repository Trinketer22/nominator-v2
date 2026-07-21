import "@acton/testing/expect"

import "@scripts/pool-utils"

fun expectParse(input: string, expected: coins?) {
    val actual = parseTonAmount(input);
    if (expected == null) {
        expect(actual == null).toBeTrue();
    } else {
        expect(actual).toNotEqual(null);
        expect(actual).toEqual(expected);
    }
}

get fun `test parseTonAmount parses integer amounts`() {
    expectParse("0", 0);
    expectParse("1", ton("1"));
    expectParse("250", ton("250"));
    expectParse("300000", ton("300000"));
    expectParse("10000000", ton("10000000"));
}

get fun `test parseTonAmount parses decimal amounts`() {
    expectParse("1.5", ton("1.5"));
    expectParse("0.001", ton("0.001"));
    expectParse("0.000000001", 1);
    expectParse("123.456789", ton("123.456789"));
    expectParse("123.456789001", 123456789001);
    expectParse("0.1", ton("0.1"));
    expectParse("0.5", ton("0.5"));
    expectParse("10.5", ton("10.5"));
}

get fun `test parseTonAmount handles plus sign`() {
    expectParse("+1", ton("1"));
    expectParse("+1.5", ton("1.5"));
    expectParse("+0", 0);
}

get fun `test parseTonAmount pads fractional part to 9 digits`() {
    expectParse("1.1", 1100000000);
    expectParse("1.01", 1010000000);
    expectParse("1.001", 1001000000);
    expectParse("1.0001", 1000100000);
    expectParse("1.0000001", 1000000100);
}

get fun `test parseTonAmount truncates extra fractional digits beyond 9`() {
    expectParse("1.1234567891", 1123456789);
    expectParse("1.1234567899", 1123456789);
    expectParse("0.9999999999", 999999999);
}

get fun `test parseTonAmount rejects empty string`() {
    expectParse("", null);
}

get fun `test parseTonAmount rejects non-numeric input`() {
    expectParse("abc", null);
    expectParse("1abc", null);
    expectParse("abc1", null);
    expectParse("1.2.3", null);
    expectParse("..5", null);
    expectParse("1..", null);
    expectParse(".", null);
    expectParse("-", null);
    expectParse("+", null);
}

get fun `test parseTonAmount rejects negative amounts`() {
    expectParse("-5", null);
    expectParse("-0.001", null);
    expectParse("-1.5", null);
}

get fun `test parseTonAmount rejects whitespace`() {
    expectParse("  10  ", null);
    expectParse(" 10", null);
    expectParse("10 ", null);
    expectParse("1 0", null);
    expectParse("1 . 5", null);
}

get fun `test parseTonAmount handles large amounts`() {
    expectParse("10000000", ton("10000000"));
    expectParse("999999999.999999999", 999999999999999999);
    expectParse("1000000.5", 1000000500000000);
}

get fun `test coinsToTonString formats integer amounts without decimals`() {
    expect(coinsToTonString(0)).toEqual("0");
    expect(coinsToTonString(ton("1"))).toEqual("1");
    expect(coinsToTonString(ton("250"))).toEqual("250");
    expect(coinsToTonString(ton("300000"))).toEqual("300000");
}

get fun `test coinsToTonString formats decimal amounts with trailing zeros stripped`() {
    expect(coinsToTonString(ton("1.5"))).toEqual("1.5");
    expect(coinsToTonString(ton("0.001"))).toEqual("0.001");
    expect(coinsToTonString(1)).toEqual("0.000000001");
    expect(coinsToTonString(ton("123.456789"))).toEqual("123.456789");
    expect(coinsToTonString(123456789001)).toEqual("123.456789001");
    expect(coinsToTonString(ton("0.1"))).toEqual("0.1");
    expect(coinsToTonString(ton("10.5"))).toEqual("10.5");
}

get fun `test coinsToTonString pads leading zeros in fractional part`() {
    expect(coinsToTonString(ton("0.001"))).toEqual("0.001");
    expect(coinsToTonString(ton("0.0001"))).toEqual("0.0001");
    expect(coinsToTonString(ton("0.0000001"))).toEqual("0.0000001");
    expect(coinsToTonString(100)).toEqual("0.0000001");
}

get fun `test coinsToTonString and parseTonAmount roundtrip`() {
    val amounts: array<coins> = [
        0,
        1,
        1000000000,
        250000000000,
        1500000000,
        1000000,
        123456789001,
        999999999,
        100,
        ton("300000"),
        ton("10000000"),
        ton("0.5"),
        ton("0.05"),
        ton("0.005"),
    ];

    var i = 0;
    repeat (amounts.size()) {
        val a = amounts.get(i);
        val s = coinsToTonString(a);
        val back = parseTonAmount(s);
        expect(back).toNotEqual(null);
        expect(back).toEqual(a);
        i += 1;
    }
}

get fun `test coinsToTonString preserves exact nanogram precision`() {
    val a = 123456789;
    val s = coinsToTonString(a);
    expect(s).toEqual("0.123456789");
    expect(parseTonAmount(s)).toEqual(a);
}

import "@contracts/types"

@inline
fun mulDivQuiet(multA: int, multB: int, divisor: int): int {
    if (multB == divisor) {
        return multA;
    }
    return multB == divisor ? multA : mulDivFloor(multA, multB, divisor);
}

@inline
fun calcSharePrice(share: int, totalTon: int, totalShares: int): int {
    return mulDivQuiet(share, totalTon, totalShares);
}

@inline
fun calcShareCount(tonAmount: int, totalShares: int, totalTon: int): int {
    return mulDivQuiet(tonAmount, totalShares, totalTon);
}

@inline
fun toBitIndex(value: int): int {
    return 2 - (value & 1);
}

fun parityToMask(isOdd: bool): int {
    // 2 + isOdd as int since true is -1???
    return 2 + (isOdd as int);
    /*
    if(isOdd) {
        return RoundAllowance.inOddRounds as int;
    }
    return RoundAllowance.inEvenRounds as int;
    */
}

fun getMaxPunishmentInt(stake: int): int {
    val punishmentConf = blockchain.configParam(40);

    if (punishmentConf == null) {
        return ton("101");
    }

    val parsedConf = PushishmentConfig.fromCell(punishmentConf);

    var fine = parsedConf.defaultFlatFine;
    var finePart = parsedConf.defaultProportionalFine;

    fine *= parsedConf.severityFlatMult;
    fine >>= 8;

    finePart *= parsedConf.severityProportinalMult;
    finePart >>= 8;

    fine *= parsedConf.longFlatMult;
    fine >>= 8;

    finePart *= parsedConf.longProportinalMult;
    finePart >>= 8;

    return min(stake, fine + mulDivFloor(stake, finePart, 1 << 32));
}

fun address.getHash(self) {
    return self.getWorkchainAndHash().1;
}

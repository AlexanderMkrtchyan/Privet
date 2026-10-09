bool get isSupported => false;

Future<bool> ensurePrimary({void Function(String? activationToken)? onRaise}) async =>
    true;

void exitSecondary() {}

Future<void> shutdown() async {}

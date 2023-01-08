// ignore_for_file: avoid_catching_errors

import 'package:conduit_core/conduit_core.dart';
import 'package:test/test.dart';

class InvalidCyclicLeft extends ManagedObject<_InvalidCyclicLeft> {}

class _InvalidCyclicLeft {
  @primaryKey
  int? id;

  @Relate(Symbol('ref'))
  InvalidCyclicRight? ref;
}

class InvalidCyclicRight extends ManagedObject<_InvalidCyclicRight> {}

class _InvalidCyclicRight {
  @primaryKey
  int? id;

  @Relate(Symbol('ref'))
  InvalidCyclicLeft? ref;
}

void main() {
  test("Both properties have Relationship metadata", () {
    try {
      final _ = ManagedDataModel([InvalidCyclicLeft, InvalidCyclicRight]);
      expect(true, false);
    } on ManagedDataModelError catch (e) {
      expect(e.message, contains("_InvalidCyclicLeft"));
      expect(e.message, contains("_InvalidCyclicRight"));
      expect(e.message, contains("but only one can"));
    }
  });
}
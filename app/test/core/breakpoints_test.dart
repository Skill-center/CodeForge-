import 'package:codeforge/core/platform/breakpoints.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formFactorFor', () {
    test('gate sizes map to the documented form factors', () {
      expect(formFactorFor(360), CfFormFactor.compact);
      expect(formFactorFor(412), CfFormFactor.compact);
      expect(formFactorFor(599), CfFormFactor.compact);
      expect(formFactorFor(600), CfFormFactor.medium);
      expect(formFactorFor(800), CfFormFactor.medium);
      expect(formFactorFor(840), CfFormFactor.medium);
      expect(formFactorFor(841), CfFormFactor.expanded);
      expect(formFactorFor(1280), CfFormFactor.expanded);
    });
  });

  group('isLandscapeSurface', () {
    test('decides from the surface, not the device', () {
      expect(isLandscapeSurface(800, 360), isTrue);
      expect(isLandscapeSurface(360, 800), isFalse);
      expect(isLandscapeSurface(500, 500), isFalse);
    });
  });
}

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sapoche/data/photo_picker.dart';
import 'package:sapoche/data/room_controller.dart';

const _limit = RoomController.maxAvatarChars ~/ 4 * 3;

Uint8List _png(img.Image picture) => img.encodePng(picture);

void main() {
  test('takes the middle square of a wide picture and scales it to 256 px', () {
    // Red, green and blue thirds side by side: the middle square is the green one
    final wide = img.Image(width: 1200, height: 400);
    for (final p in wide) {
      final third = p.x ~/ 400;
      p.setRgb(
        third == 0 ? 255 : 0,
        third == 1 ? 255 : 0,
        third == 2 ? 255 : 0,
      );
    }
    final avatar = img.decodeJpg(squareAvatar(_png(wide))!)!;
    expect((avatar.width, avatar.height), (256, 256));
    for (final (x, y) in [(0, 0), (255, 0), (0, 255), (255, 255), (128, 128)]) {
      final pixel = avatar.getPixel(x, y);
      expect(pixel.g, greaterThan(200), reason: 'at $x,$y');
      expect(pixel.r, lessThan(60), reason: 'at $x,$y');
      expect(pixel.b, lessThan(60), reason: 'at $x,$y');
    }
  });

  test('lowers the quality until the picture fits what the room accepts', () {
    // A busy picture: at the best quality it is far over the limit
    final random = Random(7);
    final busy = img.Image(width: 1024, height: 768);
    for (final p in busy) {
      final base = 128 + 80 * sin(p.x / 9) * cos(p.y / 7);
      p.setRgb(
        base + random.nextInt(120) - 60,
        base + random.nextInt(120) - 60,
        base + random.nextInt(120) - 60,
      );
    }
    final scaled = img.copyResize(
      busy,
      width: 256,
      height: 256,
      interpolation: img.Interpolation.average,
    );
    expect(img.encodeJpg(scaled, quality: 90).length, greaterThan(_limit));

    final avatar = squareAvatar(_png(busy))!;
    expect(avatar.length, lessThanOrEqualTo(_limit));
    expect(img.decodeJpg(avatar)!.width, 256);
  });

  test('does not scale a small picture up', () {
    final small = img.Image(width: 100, height: 150);
    final avatar = img.decodeJpg(squareAvatar(_png(small))!)!;
    expect((avatar.width, avatar.height), (100, 100));
  });

  test('gives nothing for something that is not a picture', () {
    expect(squareAvatar(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  group('leaves no EXIF (where the photo was taken) in what is sent to the room', () {
    // A photo as a phone makes it: a camera make, a place and a turned orientation
    Uint8List located() {
      final photo = img.Image(width: 400, height: 300);
      photo.exif.imageIfd.make = 'Camera maker';
      photo.exif.imageIfd.orientation = 6;
      photo.exif.gpsIfd['GPSLatitudeRef'] = 'N';
      photo.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(10, 1);
      final jpeg = img.encodeJpg(photo);
      expect(img.decodeJpg(jpeg)!.exif.gpsIfd.isEmpty, isFalse, reason: 'the test photo has a place');
      return jpeg;
    }

    test('an avatar', () {
      expect(img.decodeJpg(squareAvatar(located())!)!.exif.isEmpty, isTrue);
    });

    test('a photo to place behind the chat', () {
      expect(img.decodeJpg(uprightPhoto(located())!)!.exif.isEmpty, isTrue);
    });

    test('the wallpaper cut out of it', () {
      final cut = cutWallpaper(located(), left: 0, top: 0, width: 1, height: 1)!;
      expect(img.decodeJpg(cut)!.exif.isEmpty, isTrue);
    });
  });
}

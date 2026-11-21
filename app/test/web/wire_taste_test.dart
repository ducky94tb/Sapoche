import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/wire.dart';

void main() {
  test('an offer is sent as songs, a sealed one as the envelope, and taking it back as null', () {
    final plain = jsonDecode(Wire.tasteSet(const [TasteSeed('bNp9pn0ni3I', 'Song', 'Artist')])) as Map<String, dynamic>;
    expect(plain['t'], 'taste.set');
    expect(((plain['seeds'] as List).single as Map)['v'], 'bNp9pn0ni3I');
    final taken = jsonDecode(Wire.tasteSet(null)) as Map<String, dynamic>;
    expect(taken.containsKey('seeds'), isTrue);
    expect(taken['seeds'], isNull);
    final sealed = jsonDecode(Wire.tasteSetSealed('AQE-abc')) as Map<String, dynamic>;
    expect(sealed['s'], 'AQE-abc');
    expect(sealed.containsKey('seeds'), isFalse);
    expect((jsonDecode(Wire.tasteSetSealed(null)) as Map<String, dynamic>)['s'], isNull);
  });

  test('the songs the others offered come with the request for more songs, and an older server sends none', () {
    final ask = parseServerMessage(
      '{"t":"autoplay.fill","epoch":4,"videoId":"bNp9pn0ni3I","title":"One","tastes":[{"by":"m1","seeds":[{"v":"UoXllQoqEBY","ti":"Two","ar":"x"}]},{"by":"m2","s":"AQE-sealed"}]}',
    ) as AutoplayFillMessage;
    expect(ask.tastes.map((t) => t.by), ['m1', 'm2']);
    expect(ask.tastes[0].seeds!.single.v, 'UoXllQoqEBY');
    expect(ask.tastes[1].s, 'AQE-sealed');
    expect(ask.tastes[1].seeds, isNull);
    final old = parseServerMessage('{"t":"autoplay.fill","epoch":4,"videoId":"bNp9pn0ni3I","title":"One"}') as AutoplayFillMessage;
    expect(old.tastes, isEmpty);
  });

  test('explicit and year travel in queue messages and default when omitted', () {
    final add = jsonDecode(Wire.queueAdd(const TrackRef('bNp9pn0ni3I', 'Song', 'Artist', null, 180000, explicit: true, year: '2017'))) as Map<String, dynamic>;
    expect(add['explicit'], isTrue);
    expect(add['year'], '2017');
    final plain = jsonDecode(Wire.queueAdd(const TrackRef('bNp9pn0ni3I', 'Song', 'Artist', null, 180000))) as Map<String, dynamic>;
    expect(plain.containsKey('explicit'), isFalse);
    expect(plain.containsKey('year'), isFalse);

    final prep = parseServerMessage(
      '{"t":"prepare","epoch":1,"index":0,"seekToMs":0,"item":{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"Artist","durMs":180000,"addedBy":"u1","explicit":true,"year":"2017"}}',
    ) as PrepareMessage;
    expect(prep.item.explicit, isTrue);
    expect(prep.item.year, '2017');

    final oldPrep = parseServerMessage(
      '{"t":"prepare","epoch":1,"index":0,"seekToMs":0,"item":{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"Artist","durMs":180000,"addedBy":"u1"}}',
    ) as PrepareMessage;
    expect(oldPrep.item.explicit, isFalse);
    expect(oldPrep.item.year, isNull);
  });
}

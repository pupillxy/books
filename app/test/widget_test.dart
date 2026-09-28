import 'package:flutter_test/flutter_test.dart';

import 'package:xiaoshuo_app/models.dart';

void main() {
  test('Book.coverUrl 从服务器绝对路径换算为 /covers URL', () {
    final book = Book(
      id: 1,
      title: '测试',
      author: '',
      intro: '',
      cover: '/data/downloads/我的书/cover.jpg',
      fanqieId: '',
      totalChapters: 0,
    );
    expect(
      book.coverUrl('http://192.168.1.10:8080'),
      'http://192.168.1.10:8080/covers/%E6%88%91%E7%9A%84%E4%B9%A6/cover.jpg',
    );
  });

  test('Book.coverUrl 空封面返回 null', () {
    final book = Book(
      id: 1,
      title: '测试',
      author: '',
      intro: '',
      cover: '',
      fanqieId: '',
      totalChapters: 0,
    );
    expect(book.coverUrl('http://x:8080'), isNull);
  });
}

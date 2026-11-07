// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $WorkspacesTable extends Workspaces
    with TableInfo<$WorkspacesTable, WorkspaceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WorkspacesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastOpenedAtMeta = const VerificationMeta(
    'lastOpenedAt',
  );
  @override
  late final GeneratedColumn<int> lastOpenedAt = GeneratedColumn<int>(
    'last_opened_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, lastOpenedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'workspaces';
  @override
  VerificationContext validateIntegrity(
    Insertable<WorkspaceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('last_opened_at')) {
      context.handle(
        _lastOpenedAtMeta,
        lastOpenedAt.isAcceptableOrUnknown(
          data['last_opened_at']!,
          _lastOpenedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastOpenedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WorkspaceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WorkspaceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      lastOpenedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_opened_at'],
      )!,
    );
  }

  @override
  $WorkspacesTable createAlias(String alias) {
    return $WorkspacesTable(attachedDatabase, alias);
  }
}

class WorkspaceRow extends DataClass implements Insertable<WorkspaceRow> {
  /// Stable id: `demo` for the built-in workspace.
  final String id;

  /// What the user sees.
  final String name;

  /// When it was last opened, milliseconds since the epoch (UTC).
  final int lastOpenedAt;
  const WorkspaceRow({
    required this.id,
    required this.name,
    required this.lastOpenedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['last_opened_at'] = Variable<int>(lastOpenedAt);
    return map;
  }

  WorkspacesCompanion toCompanion(bool nullToAbsent) {
    return WorkspacesCompanion(
      id: Value(id),
      name: Value(name),
      lastOpenedAt: Value(lastOpenedAt),
    );
  }

  factory WorkspaceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WorkspaceRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      lastOpenedAt: serializer.fromJson<int>(json['lastOpenedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'lastOpenedAt': serializer.toJson<int>(lastOpenedAt),
    };
  }

  WorkspaceRow copyWith({String? id, String? name, int? lastOpenedAt}) =>
      WorkspaceRow(
        id: id ?? this.id,
        name: name ?? this.name,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      );
  WorkspaceRow copyWithCompanion(WorkspacesCompanion data) {
    return WorkspaceRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      lastOpenedAt: data.lastOpenedAt.present
          ? data.lastOpenedAt.value
          : this.lastOpenedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WorkspaceRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('lastOpenedAt: $lastOpenedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, lastOpenedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorkspaceRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.lastOpenedAt == this.lastOpenedAt);
}

class WorkspacesCompanion extends UpdateCompanion<WorkspaceRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> lastOpenedAt;
  final Value<int> rowid;
  const WorkspacesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.lastOpenedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorkspacesCompanion.insert({
    required String id,
    required String name,
    required int lastOpenedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       lastOpenedAt = Value(lastOpenedAt);
  static Insertable<WorkspaceRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? lastOpenedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (lastOpenedAt != null) 'last_opened_at': lastOpenedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorkspacesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? lastOpenedAt,
    Value<int>? rowid,
  }) {
    return WorkspacesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (lastOpenedAt.present) {
      map['last_opened_at'] = Variable<int>(lastOpenedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorkspacesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('lastOpenedAt: $lastOpenedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OpenTabsTable extends OpenTabs
    with TableInfo<$OpenTabsTable, OpenTabRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OpenTabsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _workspaceIdMeta = const VerificationMeta(
    'workspaceId',
  );
  @override
  late final GeneratedColumn<String> workspaceId = GeneratedColumn<String>(
    'workspace_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _activeMeta = const VerificationMeta('active');
  @override
  late final GeneratedColumn<bool> active = GeneratedColumn<bool>(
    'active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("active" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _selectionAnchorMeta = const VerificationMeta(
    'selectionAnchor',
  );
  @override
  late final GeneratedColumn<int> selectionAnchor = GeneratedColumn<int>(
    'selection_anchor',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _selectionHeadMeta = const VerificationMeta(
    'selectionHead',
  );
  @override
  late final GeneratedColumn<int> selectionHead = GeneratedColumn<int>(
    'selection_head',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scrollTopMeta = const VerificationMeta(
    'scrollTop',
  );
  @override
  late final GeneratedColumn<double> scrollTop = GeneratedColumn<double>(
    'scroll_top',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    workspaceId,
    path,
    position,
    active,
    selectionAnchor,
    selectionHead,
    scrollTop,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'open_tabs';
  @override
  VerificationContext validateIntegrity(
    Insertable<OpenTabRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('workspace_id')) {
      context.handle(
        _workspaceIdMeta,
        workspaceId.isAcceptableOrUnknown(
          data['workspace_id']!,
          _workspaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_workspaceIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('active')) {
      context.handle(
        _activeMeta,
        active.isAcceptableOrUnknown(data['active']!, _activeMeta),
      );
    }
    if (data.containsKey('selection_anchor')) {
      context.handle(
        _selectionAnchorMeta,
        selectionAnchor.isAcceptableOrUnknown(
          data['selection_anchor']!,
          _selectionAnchorMeta,
        ),
      );
    }
    if (data.containsKey('selection_head')) {
      context.handle(
        _selectionHeadMeta,
        selectionHead.isAcceptableOrUnknown(
          data['selection_head']!,
          _selectionHeadMeta,
        ),
      );
    }
    if (data.containsKey('scroll_top')) {
      context.handle(
        _scrollTopMeta,
        scrollTop.isAcceptableOrUnknown(data['scroll_top']!, _scrollTopMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {workspaceId, path};
  @override
  OpenTabRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OpenTabRow(
      workspaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workspace_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      active: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}active'],
      )!,
      selectionAnchor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}selection_anchor'],
      ),
      selectionHead: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}selection_head'],
      ),
      scrollTop: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}scroll_top'],
      )!,
    );
  }

  @override
  $OpenTabsTable createAlias(String alias) {
    return $OpenTabsTable(attachedDatabase, alias);
  }
}

class OpenTabRow extends DataClass implements Insertable<OpenTabRow> {
  final String workspaceId;

  /// Workspace-relative path.
  final String path;

  /// Place in the tab strip, from 0.
  final int position;

  /// The tab that was showing.
  final bool active;

  /// Selection in UTF-16 offsets; null when the editor never reported one.
  final int? selectionAnchor;
  final int? selectionHead;

  /// Vertical scroll offset in CSS pixels.
  final double scrollTop;
  const OpenTabRow({
    required this.workspaceId,
    required this.path,
    required this.position,
    required this.active,
    this.selectionAnchor,
    this.selectionHead,
    required this.scrollTop,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['workspace_id'] = Variable<String>(workspaceId);
    map['path'] = Variable<String>(path);
    map['position'] = Variable<int>(position);
    map['active'] = Variable<bool>(active);
    if (!nullToAbsent || selectionAnchor != null) {
      map['selection_anchor'] = Variable<int>(selectionAnchor);
    }
    if (!nullToAbsent || selectionHead != null) {
      map['selection_head'] = Variable<int>(selectionHead);
    }
    map['scroll_top'] = Variable<double>(scrollTop);
    return map;
  }

  OpenTabsCompanion toCompanion(bool nullToAbsent) {
    return OpenTabsCompanion(
      workspaceId: Value(workspaceId),
      path: Value(path),
      position: Value(position),
      active: Value(active),
      selectionAnchor: selectionAnchor == null && nullToAbsent
          ? const Value.absent()
          : Value(selectionAnchor),
      selectionHead: selectionHead == null && nullToAbsent
          ? const Value.absent()
          : Value(selectionHead),
      scrollTop: Value(scrollTop),
    );
  }

  factory OpenTabRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OpenTabRow(
      workspaceId: serializer.fromJson<String>(json['workspaceId']),
      path: serializer.fromJson<String>(json['path']),
      position: serializer.fromJson<int>(json['position']),
      active: serializer.fromJson<bool>(json['active']),
      selectionAnchor: serializer.fromJson<int?>(json['selectionAnchor']),
      selectionHead: serializer.fromJson<int?>(json['selectionHead']),
      scrollTop: serializer.fromJson<double>(json['scrollTop']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'workspaceId': serializer.toJson<String>(workspaceId),
      'path': serializer.toJson<String>(path),
      'position': serializer.toJson<int>(position),
      'active': serializer.toJson<bool>(active),
      'selectionAnchor': serializer.toJson<int?>(selectionAnchor),
      'selectionHead': serializer.toJson<int?>(selectionHead),
      'scrollTop': serializer.toJson<double>(scrollTop),
    };
  }

  OpenTabRow copyWith({
    String? workspaceId,
    String? path,
    int? position,
    bool? active,
    Value<int?> selectionAnchor = const Value.absent(),
    Value<int?> selectionHead = const Value.absent(),
    double? scrollTop,
  }) => OpenTabRow(
    workspaceId: workspaceId ?? this.workspaceId,
    path: path ?? this.path,
    position: position ?? this.position,
    active: active ?? this.active,
    selectionAnchor: selectionAnchor.present
        ? selectionAnchor.value
        : this.selectionAnchor,
    selectionHead: selectionHead.present
        ? selectionHead.value
        : this.selectionHead,
    scrollTop: scrollTop ?? this.scrollTop,
  );
  OpenTabRow copyWithCompanion(OpenTabsCompanion data) {
    return OpenTabRow(
      workspaceId: data.workspaceId.present
          ? data.workspaceId.value
          : this.workspaceId,
      path: data.path.present ? data.path.value : this.path,
      position: data.position.present ? data.position.value : this.position,
      active: data.active.present ? data.active.value : this.active,
      selectionAnchor: data.selectionAnchor.present
          ? data.selectionAnchor.value
          : this.selectionAnchor,
      selectionHead: data.selectionHead.present
          ? data.selectionHead.value
          : this.selectionHead,
      scrollTop: data.scrollTop.present ? data.scrollTop.value : this.scrollTop,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OpenTabRow(')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('position: $position, ')
          ..write('active: $active, ')
          ..write('selectionAnchor: $selectionAnchor, ')
          ..write('selectionHead: $selectionHead, ')
          ..write('scrollTop: $scrollTop')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    workspaceId,
    path,
    position,
    active,
    selectionAnchor,
    selectionHead,
    scrollTop,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OpenTabRow &&
          other.workspaceId == this.workspaceId &&
          other.path == this.path &&
          other.position == this.position &&
          other.active == this.active &&
          other.selectionAnchor == this.selectionAnchor &&
          other.selectionHead == this.selectionHead &&
          other.scrollTop == this.scrollTop);
}

class OpenTabsCompanion extends UpdateCompanion<OpenTabRow> {
  final Value<String> workspaceId;
  final Value<String> path;
  final Value<int> position;
  final Value<bool> active;
  final Value<int?> selectionAnchor;
  final Value<int?> selectionHead;
  final Value<double> scrollTop;
  final Value<int> rowid;
  const OpenTabsCompanion({
    this.workspaceId = const Value.absent(),
    this.path = const Value.absent(),
    this.position = const Value.absent(),
    this.active = const Value.absent(),
    this.selectionAnchor = const Value.absent(),
    this.selectionHead = const Value.absent(),
    this.scrollTop = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OpenTabsCompanion.insert({
    required String workspaceId,
    required String path,
    required int position,
    this.active = const Value.absent(),
    this.selectionAnchor = const Value.absent(),
    this.selectionHead = const Value.absent(),
    this.scrollTop = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : workspaceId = Value(workspaceId),
       path = Value(path),
       position = Value(position);
  static Insertable<OpenTabRow> custom({
    Expression<String>? workspaceId,
    Expression<String>? path,
    Expression<int>? position,
    Expression<bool>? active,
    Expression<int>? selectionAnchor,
    Expression<int>? selectionHead,
    Expression<double>? scrollTop,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (path != null) 'path': path,
      if (position != null) 'position': position,
      if (active != null) 'active': active,
      if (selectionAnchor != null) 'selection_anchor': selectionAnchor,
      if (selectionHead != null) 'selection_head': selectionHead,
      if (scrollTop != null) 'scroll_top': scrollTop,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OpenTabsCompanion copyWith({
    Value<String>? workspaceId,
    Value<String>? path,
    Value<int>? position,
    Value<bool>? active,
    Value<int?>? selectionAnchor,
    Value<int?>? selectionHead,
    Value<double>? scrollTop,
    Value<int>? rowid,
  }) {
    return OpenTabsCompanion(
      workspaceId: workspaceId ?? this.workspaceId,
      path: path ?? this.path,
      position: position ?? this.position,
      active: active ?? this.active,
      selectionAnchor: selectionAnchor ?? this.selectionAnchor,
      selectionHead: selectionHead ?? this.selectionHead,
      scrollTop: scrollTop ?? this.scrollTop,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (workspaceId.present) {
      map['workspace_id'] = Variable<String>(workspaceId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (active.present) {
      map['active'] = Variable<bool>(active.value);
    }
    if (selectionAnchor.present) {
      map['selection_anchor'] = Variable<int>(selectionAnchor.value);
    }
    if (selectionHead.present) {
      map['selection_head'] = Variable<int>(selectionHead.value);
    }
    if (scrollTop.present) {
      map['scroll_top'] = Variable<double>(scrollTop.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OpenTabsCompanion(')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('position: $position, ')
          ..write('active: $active, ')
          ..write('selectionAnchor: $selectionAnchor, ')
          ..write('selectionHead: $selectionHead, ')
          ..write('scrollTop: $scrollTop, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $JournalDocumentsTable extends JournalDocuments
    with TableInfo<$JournalDocumentsTable, JournalDocumentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JournalDocumentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _workspaceIdMeta = const VerificationMeta(
    'workspaceId',
  );
  @override
  late final GeneratedColumn<String> workspaceId = GeneratedColumn<String>(
    'workspace_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotTextMeta = const VerificationMeta(
    'snapshotText',
  );
  @override
  late final GeneratedColumn<String> snapshotText = GeneratedColumn<String>(
    'snapshot_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotVersionMeta = const VerificationMeta(
    'snapshotVersion',
  );
  @override
  late final GeneratedColumn<int> snapshotVersion = GeneratedColumn<int>(
    'snapshot_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseDigestMeta = const VerificationMeta(
    'baseDigest',
  );
  @override
  late final GeneratedColumn<String> baseDigest = GeneratedColumn<String>(
    'base_digest',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lineEndingMeta = const VerificationMeta(
    'lineEnding',
  );
  @override
  late final GeneratedColumn<String> lineEnding = GeneratedColumn<String>(
    'line_ending',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bomMeta = const VerificationMeta('bom');
  @override
  late final GeneratedColumn<bool> bom = GeneratedColumn<bool>(
    'bom',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("bom" IN (0, 1))',
    ),
  );
  static const VerificationMeta _languageMeta = const VerificationMeta(
    'language',
  );
  @override
  late final GeneratedColumn<String> language = GeneratedColumn<String>(
    'language',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    workspaceId,
    path,
    snapshotText,
    snapshotVersion,
    baseDigest,
    lineEnding,
    bom,
    language,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journal_documents';
  @override
  VerificationContext validateIntegrity(
    Insertable<JournalDocumentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('workspace_id')) {
      context.handle(
        _workspaceIdMeta,
        workspaceId.isAcceptableOrUnknown(
          data['workspace_id']!,
          _workspaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_workspaceIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('snapshot_text')) {
      context.handle(
        _snapshotTextMeta,
        snapshotText.isAcceptableOrUnknown(
          data['snapshot_text']!,
          _snapshotTextMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_snapshotTextMeta);
    }
    if (data.containsKey('snapshot_version')) {
      context.handle(
        _snapshotVersionMeta,
        snapshotVersion.isAcceptableOrUnknown(
          data['snapshot_version']!,
          _snapshotVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_snapshotVersionMeta);
    }
    if (data.containsKey('base_digest')) {
      context.handle(
        _baseDigestMeta,
        baseDigest.isAcceptableOrUnknown(data['base_digest']!, _baseDigestMeta),
      );
    }
    if (data.containsKey('line_ending')) {
      context.handle(
        _lineEndingMeta,
        lineEnding.isAcceptableOrUnknown(data['line_ending']!, _lineEndingMeta),
      );
    } else if (isInserting) {
      context.missing(_lineEndingMeta);
    }
    if (data.containsKey('bom')) {
      context.handle(
        _bomMeta,
        bom.isAcceptableOrUnknown(data['bom']!, _bomMeta),
      );
    } else if (isInserting) {
      context.missing(_bomMeta);
    }
    if (data.containsKey('language')) {
      context.handle(
        _languageMeta,
        language.isAcceptableOrUnknown(data['language']!, _languageMeta),
      );
    } else if (isInserting) {
      context.missing(_languageMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {workspaceId, path};
  @override
  JournalDocumentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JournalDocumentRow(
      workspaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workspace_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      snapshotText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snapshot_text'],
      )!,
      snapshotVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}snapshot_version'],
      )!,
      baseDigest: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_digest'],
      ),
      lineEnding: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}line_ending'],
      )!,
      bom: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}bom'],
      )!,
      language: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}language'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $JournalDocumentsTable createAlias(String alias) {
    return $JournalDocumentsTable(attachedDatabase, alias);
  }
}

class JournalDocumentRow extends DataClass
    implements Insertable<JournalDocumentRow> {
  final String workspaceId;

  /// Workspace-relative path.
  final String path;

  /// The document's text ("\n" line breaks) at [snapshotVersion].
  final String snapshotText;

  /// The editor's version of [snapshotText]; recorded changes continue
  /// from it.
  final int snapshotVersion;

  /// SHA-256 (hex) of the saved text the edits were made against; null
  /// when the file was gone.
  final String? baseDigest;

  /// `lf` or `crlf`: how the document is saved.
  final String lineEnding;

  /// Whether the document is saved with a UTF-8 byte-order mark.
  final bool bom;

  /// One of `editorLanguageIds`.
  final String language;

  /// When the snapshot was written, milliseconds since the epoch (UTC).
  final int updatedAt;
  const JournalDocumentRow({
    required this.workspaceId,
    required this.path,
    required this.snapshotText,
    required this.snapshotVersion,
    this.baseDigest,
    required this.lineEnding,
    required this.bom,
    required this.language,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['workspace_id'] = Variable<String>(workspaceId);
    map['path'] = Variable<String>(path);
    map['snapshot_text'] = Variable<String>(snapshotText);
    map['snapshot_version'] = Variable<int>(snapshotVersion);
    if (!nullToAbsent || baseDigest != null) {
      map['base_digest'] = Variable<String>(baseDigest);
    }
    map['line_ending'] = Variable<String>(lineEnding);
    map['bom'] = Variable<bool>(bom);
    map['language'] = Variable<String>(language);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  JournalDocumentsCompanion toCompanion(bool nullToAbsent) {
    return JournalDocumentsCompanion(
      workspaceId: Value(workspaceId),
      path: Value(path),
      snapshotText: Value(snapshotText),
      snapshotVersion: Value(snapshotVersion),
      baseDigest: baseDigest == null && nullToAbsent
          ? const Value.absent()
          : Value(baseDigest),
      lineEnding: Value(lineEnding),
      bom: Value(bom),
      language: Value(language),
      updatedAt: Value(updatedAt),
    );
  }

  factory JournalDocumentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JournalDocumentRow(
      workspaceId: serializer.fromJson<String>(json['workspaceId']),
      path: serializer.fromJson<String>(json['path']),
      snapshotText: serializer.fromJson<String>(json['snapshotText']),
      snapshotVersion: serializer.fromJson<int>(json['snapshotVersion']),
      baseDigest: serializer.fromJson<String?>(json['baseDigest']),
      lineEnding: serializer.fromJson<String>(json['lineEnding']),
      bom: serializer.fromJson<bool>(json['bom']),
      language: serializer.fromJson<String>(json['language']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'workspaceId': serializer.toJson<String>(workspaceId),
      'path': serializer.toJson<String>(path),
      'snapshotText': serializer.toJson<String>(snapshotText),
      'snapshotVersion': serializer.toJson<int>(snapshotVersion),
      'baseDigest': serializer.toJson<String?>(baseDigest),
      'lineEnding': serializer.toJson<String>(lineEnding),
      'bom': serializer.toJson<bool>(bom),
      'language': serializer.toJson<String>(language),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  JournalDocumentRow copyWith({
    String? workspaceId,
    String? path,
    String? snapshotText,
    int? snapshotVersion,
    Value<String?> baseDigest = const Value.absent(),
    String? lineEnding,
    bool? bom,
    String? language,
    int? updatedAt,
  }) => JournalDocumentRow(
    workspaceId: workspaceId ?? this.workspaceId,
    path: path ?? this.path,
    snapshotText: snapshotText ?? this.snapshotText,
    snapshotVersion: snapshotVersion ?? this.snapshotVersion,
    baseDigest: baseDigest.present ? baseDigest.value : this.baseDigest,
    lineEnding: lineEnding ?? this.lineEnding,
    bom: bom ?? this.bom,
    language: language ?? this.language,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  JournalDocumentRow copyWithCompanion(JournalDocumentsCompanion data) {
    return JournalDocumentRow(
      workspaceId: data.workspaceId.present
          ? data.workspaceId.value
          : this.workspaceId,
      path: data.path.present ? data.path.value : this.path,
      snapshotText: data.snapshotText.present
          ? data.snapshotText.value
          : this.snapshotText,
      snapshotVersion: data.snapshotVersion.present
          ? data.snapshotVersion.value
          : this.snapshotVersion,
      baseDigest: data.baseDigest.present
          ? data.baseDigest.value
          : this.baseDigest,
      lineEnding: data.lineEnding.present
          ? data.lineEnding.value
          : this.lineEnding,
      bom: data.bom.present ? data.bom.value : this.bom,
      language: data.language.present ? data.language.value : this.language,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JournalDocumentRow(')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('snapshotText: $snapshotText, ')
          ..write('snapshotVersion: $snapshotVersion, ')
          ..write('baseDigest: $baseDigest, ')
          ..write('lineEnding: $lineEnding, ')
          ..write('bom: $bom, ')
          ..write('language: $language, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    workspaceId,
    path,
    snapshotText,
    snapshotVersion,
    baseDigest,
    lineEnding,
    bom,
    language,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JournalDocumentRow &&
          other.workspaceId == this.workspaceId &&
          other.path == this.path &&
          other.snapshotText == this.snapshotText &&
          other.snapshotVersion == this.snapshotVersion &&
          other.baseDigest == this.baseDigest &&
          other.lineEnding == this.lineEnding &&
          other.bom == this.bom &&
          other.language == this.language &&
          other.updatedAt == this.updatedAt);
}

class JournalDocumentsCompanion extends UpdateCompanion<JournalDocumentRow> {
  final Value<String> workspaceId;
  final Value<String> path;
  final Value<String> snapshotText;
  final Value<int> snapshotVersion;
  final Value<String?> baseDigest;
  final Value<String> lineEnding;
  final Value<bool> bom;
  final Value<String> language;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const JournalDocumentsCompanion({
    this.workspaceId = const Value.absent(),
    this.path = const Value.absent(),
    this.snapshotText = const Value.absent(),
    this.snapshotVersion = const Value.absent(),
    this.baseDigest = const Value.absent(),
    this.lineEnding = const Value.absent(),
    this.bom = const Value.absent(),
    this.language = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  JournalDocumentsCompanion.insert({
    required String workspaceId,
    required String path,
    required String snapshotText,
    required int snapshotVersion,
    this.baseDigest = const Value.absent(),
    required String lineEnding,
    required bool bom,
    required String language,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : workspaceId = Value(workspaceId),
       path = Value(path),
       snapshotText = Value(snapshotText),
       snapshotVersion = Value(snapshotVersion),
       lineEnding = Value(lineEnding),
       bom = Value(bom),
       language = Value(language),
       updatedAt = Value(updatedAt);
  static Insertable<JournalDocumentRow> custom({
    Expression<String>? workspaceId,
    Expression<String>? path,
    Expression<String>? snapshotText,
    Expression<int>? snapshotVersion,
    Expression<String>? baseDigest,
    Expression<String>? lineEnding,
    Expression<bool>? bom,
    Expression<String>? language,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (path != null) 'path': path,
      if (snapshotText != null) 'snapshot_text': snapshotText,
      if (snapshotVersion != null) 'snapshot_version': snapshotVersion,
      if (baseDigest != null) 'base_digest': baseDigest,
      if (lineEnding != null) 'line_ending': lineEnding,
      if (bom != null) 'bom': bom,
      if (language != null) 'language': language,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  JournalDocumentsCompanion copyWith({
    Value<String>? workspaceId,
    Value<String>? path,
    Value<String>? snapshotText,
    Value<int>? snapshotVersion,
    Value<String?>? baseDigest,
    Value<String>? lineEnding,
    Value<bool>? bom,
    Value<String>? language,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return JournalDocumentsCompanion(
      workspaceId: workspaceId ?? this.workspaceId,
      path: path ?? this.path,
      snapshotText: snapshotText ?? this.snapshotText,
      snapshotVersion: snapshotVersion ?? this.snapshotVersion,
      baseDigest: baseDigest ?? this.baseDigest,
      lineEnding: lineEnding ?? this.lineEnding,
      bom: bom ?? this.bom,
      language: language ?? this.language,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (workspaceId.present) {
      map['workspace_id'] = Variable<String>(workspaceId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (snapshotText.present) {
      map['snapshot_text'] = Variable<String>(snapshotText.value);
    }
    if (snapshotVersion.present) {
      map['snapshot_version'] = Variable<int>(snapshotVersion.value);
    }
    if (baseDigest.present) {
      map['base_digest'] = Variable<String>(baseDigest.value);
    }
    if (lineEnding.present) {
      map['line_ending'] = Variable<String>(lineEnding.value);
    }
    if (bom.present) {
      map['bom'] = Variable<bool>(bom.value);
    }
    if (language.present) {
      map['language'] = Variable<String>(language.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JournalDocumentsCompanion(')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('snapshotText: $snapshotText, ')
          ..write('snapshotVersion: $snapshotVersion, ')
          ..write('baseDigest: $baseDigest, ')
          ..write('lineEnding: $lineEnding, ')
          ..write('bom: $bom, ')
          ..write('language: $language, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $JournalChangesTable extends JournalChanges
    with TableInfo<$JournalChangesTable, JournalChangeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JournalChangesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _workspaceIdMeta = const VerificationMeta(
    'workspaceId',
  );
  @override
  late final GeneratedColumn<String> workspaceId = GeneratedColumn<String>(
    'workspace_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseVersionMeta = const VerificationMeta(
    'baseVersion',
  );
  @override
  late final GeneratedColumn<int> baseVersion = GeneratedColumn<int>(
    'base_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lengthBeforeMeta = const VerificationMeta(
    'lengthBefore',
  );
  @override
  late final GeneratedColumn<int> lengthBefore = GeneratedColumn<int>(
    'length_before',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lengthAfterMeta = const VerificationMeta(
    'lengthAfter',
  );
  @override
  late final GeneratedColumn<int> lengthAfter = GeneratedColumn<int>(
    'length_after',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _changesMeta = const VerificationMeta(
    'changes',
  );
  @override
  late final GeneratedColumn<String> changes = GeneratedColumn<String>(
    'changes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    workspaceId,
    path,
    baseVersion,
    version,
    lengthBefore,
    lengthAfter,
    changes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journal_changes';
  @override
  VerificationContext validateIntegrity(
    Insertable<JournalChangeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('workspace_id')) {
      context.handle(
        _workspaceIdMeta,
        workspaceId.isAcceptableOrUnknown(
          data['workspace_id']!,
          _workspaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_workspaceIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('base_version')) {
      context.handle(
        _baseVersionMeta,
        baseVersion.isAcceptableOrUnknown(
          data['base_version']!,
          _baseVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_baseVersionMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    if (data.containsKey('length_before')) {
      context.handle(
        _lengthBeforeMeta,
        lengthBefore.isAcceptableOrUnknown(
          data['length_before']!,
          _lengthBeforeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lengthBeforeMeta);
    }
    if (data.containsKey('length_after')) {
      context.handle(
        _lengthAfterMeta,
        lengthAfter.isAcceptableOrUnknown(
          data['length_after']!,
          _lengthAfterMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lengthAfterMeta);
    }
    if (data.containsKey('changes')) {
      context.handle(
        _changesMeta,
        changes.isAcceptableOrUnknown(data['changes']!, _changesMeta),
      );
    } else if (isInserting) {
      context.missing(_changesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  JournalChangeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JournalChangeRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      workspaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workspace_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      baseVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_version'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      lengthBefore: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}length_before'],
      )!,
      lengthAfter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}length_after'],
      )!,
      changes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}changes'],
      )!,
    );
  }

  @override
  $JournalChangesTable createAlias(String alias) {
    return $JournalChangesTable(attachedDatabase, alias);
  }
}

class JournalChangeRow extends DataClass
    implements Insertable<JournalChangeRow> {
  final int id;
  final String workspaceId;

  /// Workspace-relative path.
  final String path;

  /// The version this change applies to, and the version it makes.
  final int baseVersion;
  final int version;

  /// Text lengths before and after, checked on replay.
  final int lengthBefore;
  final int lengthAfter;

  /// CodeMirror change-set JSON (core/editor/change_set.dart).
  final String changes;
  const JournalChangeRow({
    required this.id,
    required this.workspaceId,
    required this.path,
    required this.baseVersion,
    required this.version,
    required this.lengthBefore,
    required this.lengthAfter,
    required this.changes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['workspace_id'] = Variable<String>(workspaceId);
    map['path'] = Variable<String>(path);
    map['base_version'] = Variable<int>(baseVersion);
    map['version'] = Variable<int>(version);
    map['length_before'] = Variable<int>(lengthBefore);
    map['length_after'] = Variable<int>(lengthAfter);
    map['changes'] = Variable<String>(changes);
    return map;
  }

  JournalChangesCompanion toCompanion(bool nullToAbsent) {
    return JournalChangesCompanion(
      id: Value(id),
      workspaceId: Value(workspaceId),
      path: Value(path),
      baseVersion: Value(baseVersion),
      version: Value(version),
      lengthBefore: Value(lengthBefore),
      lengthAfter: Value(lengthAfter),
      changes: Value(changes),
    );
  }

  factory JournalChangeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JournalChangeRow(
      id: serializer.fromJson<int>(json['id']),
      workspaceId: serializer.fromJson<String>(json['workspaceId']),
      path: serializer.fromJson<String>(json['path']),
      baseVersion: serializer.fromJson<int>(json['baseVersion']),
      version: serializer.fromJson<int>(json['version']),
      lengthBefore: serializer.fromJson<int>(json['lengthBefore']),
      lengthAfter: serializer.fromJson<int>(json['lengthAfter']),
      changes: serializer.fromJson<String>(json['changes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'workspaceId': serializer.toJson<String>(workspaceId),
      'path': serializer.toJson<String>(path),
      'baseVersion': serializer.toJson<int>(baseVersion),
      'version': serializer.toJson<int>(version),
      'lengthBefore': serializer.toJson<int>(lengthBefore),
      'lengthAfter': serializer.toJson<int>(lengthAfter),
      'changes': serializer.toJson<String>(changes),
    };
  }

  JournalChangeRow copyWith({
    int? id,
    String? workspaceId,
    String? path,
    int? baseVersion,
    int? version,
    int? lengthBefore,
    int? lengthAfter,
    String? changes,
  }) => JournalChangeRow(
    id: id ?? this.id,
    workspaceId: workspaceId ?? this.workspaceId,
    path: path ?? this.path,
    baseVersion: baseVersion ?? this.baseVersion,
    version: version ?? this.version,
    lengthBefore: lengthBefore ?? this.lengthBefore,
    lengthAfter: lengthAfter ?? this.lengthAfter,
    changes: changes ?? this.changes,
  );
  JournalChangeRow copyWithCompanion(JournalChangesCompanion data) {
    return JournalChangeRow(
      id: data.id.present ? data.id.value : this.id,
      workspaceId: data.workspaceId.present
          ? data.workspaceId.value
          : this.workspaceId,
      path: data.path.present ? data.path.value : this.path,
      baseVersion: data.baseVersion.present
          ? data.baseVersion.value
          : this.baseVersion,
      version: data.version.present ? data.version.value : this.version,
      lengthBefore: data.lengthBefore.present
          ? data.lengthBefore.value
          : this.lengthBefore,
      lengthAfter: data.lengthAfter.present
          ? data.lengthAfter.value
          : this.lengthAfter,
      changes: data.changes.present ? data.changes.value : this.changes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JournalChangeRow(')
          ..write('id: $id, ')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('version: $version, ')
          ..write('lengthBefore: $lengthBefore, ')
          ..write('lengthAfter: $lengthAfter, ')
          ..write('changes: $changes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    workspaceId,
    path,
    baseVersion,
    version,
    lengthBefore,
    lengthAfter,
    changes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JournalChangeRow &&
          other.id == this.id &&
          other.workspaceId == this.workspaceId &&
          other.path == this.path &&
          other.baseVersion == this.baseVersion &&
          other.version == this.version &&
          other.lengthBefore == this.lengthBefore &&
          other.lengthAfter == this.lengthAfter &&
          other.changes == this.changes);
}

class JournalChangesCompanion extends UpdateCompanion<JournalChangeRow> {
  final Value<int> id;
  final Value<String> workspaceId;
  final Value<String> path;
  final Value<int> baseVersion;
  final Value<int> version;
  final Value<int> lengthBefore;
  final Value<int> lengthAfter;
  final Value<String> changes;
  const JournalChangesCompanion({
    this.id = const Value.absent(),
    this.workspaceId = const Value.absent(),
    this.path = const Value.absent(),
    this.baseVersion = const Value.absent(),
    this.version = const Value.absent(),
    this.lengthBefore = const Value.absent(),
    this.lengthAfter = const Value.absent(),
    this.changes = const Value.absent(),
  });
  JournalChangesCompanion.insert({
    this.id = const Value.absent(),
    required String workspaceId,
    required String path,
    required int baseVersion,
    required int version,
    required int lengthBefore,
    required int lengthAfter,
    required String changes,
  }) : workspaceId = Value(workspaceId),
       path = Value(path),
       baseVersion = Value(baseVersion),
       version = Value(version),
       lengthBefore = Value(lengthBefore),
       lengthAfter = Value(lengthAfter),
       changes = Value(changes);
  static Insertable<JournalChangeRow> custom({
    Expression<int>? id,
    Expression<String>? workspaceId,
    Expression<String>? path,
    Expression<int>? baseVersion,
    Expression<int>? version,
    Expression<int>? lengthBefore,
    Expression<int>? lengthAfter,
    Expression<String>? changes,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (path != null) 'path': path,
      if (baseVersion != null) 'base_version': baseVersion,
      if (version != null) 'version': version,
      if (lengthBefore != null) 'length_before': lengthBefore,
      if (lengthAfter != null) 'length_after': lengthAfter,
      if (changes != null) 'changes': changes,
    });
  }

  JournalChangesCompanion copyWith({
    Value<int>? id,
    Value<String>? workspaceId,
    Value<String>? path,
    Value<int>? baseVersion,
    Value<int>? version,
    Value<int>? lengthBefore,
    Value<int>? lengthAfter,
    Value<String>? changes,
  }) {
    return JournalChangesCompanion(
      id: id ?? this.id,
      workspaceId: workspaceId ?? this.workspaceId,
      path: path ?? this.path,
      baseVersion: baseVersion ?? this.baseVersion,
      version: version ?? this.version,
      lengthBefore: lengthBefore ?? this.lengthBefore,
      lengthAfter: lengthAfter ?? this.lengthAfter,
      changes: changes ?? this.changes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (workspaceId.present) {
      map['workspace_id'] = Variable<String>(workspaceId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (baseVersion.present) {
      map['base_version'] = Variable<int>(baseVersion.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (lengthBefore.present) {
      map['length_before'] = Variable<int>(lengthBefore.value);
    }
    if (lengthAfter.present) {
      map['length_after'] = Variable<int>(lengthAfter.value);
    }
    if (changes.present) {
      map['changes'] = Variable<String>(changes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JournalChangesCompanion(')
          ..write('id: $id, ')
          ..write('workspaceId: $workspaceId, ')
          ..write('path: $path, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('version: $version, ')
          ..write('lengthBefore: $lengthBefore, ')
          ..write('lengthAfter: $lengthAfter, ')
          ..write('changes: $changes')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $WorkspacesTable workspaces = $WorkspacesTable(this);
  late final $OpenTabsTable openTabs = $OpenTabsTable(this);
  late final $JournalDocumentsTable journalDocuments = $JournalDocumentsTable(
    this,
  );
  late final $JournalChangesTable journalChanges = $JournalChangesTable(this);
  late final Index journalChangesDocument = Index(
    'journal_changes_document',
    'CREATE INDEX journal_changes_document ON journal_changes (workspace_id, path, version)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    workspaces,
    openTabs,
    journalDocuments,
    journalChanges,
    journalChangesDocument,
  ];
}

typedef $$WorkspacesTableCreateCompanionBuilder =
    WorkspacesCompanion Function({
      required String id,
      required String name,
      required int lastOpenedAt,
      Value<int> rowid,
    });
typedef $$WorkspacesTableUpdateCompanionBuilder =
    WorkspacesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int> lastOpenedAt,
      Value<int> rowid,
    });

class $$WorkspacesTableFilterComposer
    extends Composer<_$AppDatabase, $WorkspacesTable> {
  $$WorkspacesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastOpenedAt => $composableBuilder(
    column: $table.lastOpenedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WorkspacesTableOrderingComposer
    extends Composer<_$AppDatabase, $WorkspacesTable> {
  $$WorkspacesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastOpenedAt => $composableBuilder(
    column: $table.lastOpenedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WorkspacesTableAnnotationComposer
    extends Composer<_$AppDatabase, $WorkspacesTable> {
  $$WorkspacesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get lastOpenedAt => $composableBuilder(
    column: $table.lastOpenedAt,
    builder: (column) => column,
  );
}

class $$WorkspacesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WorkspacesTable,
          WorkspaceRow,
          $$WorkspacesTableFilterComposer,
          $$WorkspacesTableOrderingComposer,
          $$WorkspacesTableAnnotationComposer,
          $$WorkspacesTableCreateCompanionBuilder,
          $$WorkspacesTableUpdateCompanionBuilder,
          (
            WorkspaceRow,
            BaseReferences<_$AppDatabase, $WorkspacesTable, WorkspaceRow>,
          ),
          WorkspaceRow,
          PrefetchHooks Function()
        > {
  $$WorkspacesTableTableManager(_$AppDatabase db, $WorkspacesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WorkspacesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WorkspacesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WorkspacesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> lastOpenedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorkspacesCompanion(
                id: id,
                name: name,
                lastOpenedAt: lastOpenedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required int lastOpenedAt,
                Value<int> rowid = const Value.absent(),
              }) => WorkspacesCompanion.insert(
                id: id,
                name: name,
                lastOpenedAt: lastOpenedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$WorkspacesTable, WorkspaceRow>(table),
                  BaseReferences<_$AppDatabase, $WorkspacesTable, WorkspaceRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WorkspacesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WorkspacesTable,
      WorkspaceRow,
      $$WorkspacesTableFilterComposer,
      $$WorkspacesTableOrderingComposer,
      $$WorkspacesTableAnnotationComposer,
      $$WorkspacesTableCreateCompanionBuilder,
      $$WorkspacesTableUpdateCompanionBuilder,
      (
        WorkspaceRow,
        BaseReferences<_$AppDatabase, $WorkspacesTable, WorkspaceRow>,
      ),
      WorkspaceRow,
      PrefetchHooks Function()
    >;
typedef $$OpenTabsTableCreateCompanionBuilder =
    OpenTabsCompanion Function({
      required String workspaceId,
      required String path,
      required int position,
      Value<bool> active,
      Value<int?> selectionAnchor,
      Value<int?> selectionHead,
      Value<double> scrollTop,
      Value<int> rowid,
    });
typedef $$OpenTabsTableUpdateCompanionBuilder =
    OpenTabsCompanion Function({
      Value<String> workspaceId,
      Value<String> path,
      Value<int> position,
      Value<bool> active,
      Value<int?> selectionAnchor,
      Value<int?> selectionHead,
      Value<double> scrollTop,
      Value<int> rowid,
    });

class $$OpenTabsTableFilterComposer
    extends Composer<_$AppDatabase, $OpenTabsTable> {
  $$OpenTabsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get selectionAnchor => $composableBuilder(
    column: $table.selectionAnchor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get selectionHead => $composableBuilder(
    column: $table.selectionHead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get scrollTop => $composableBuilder(
    column: $table.scrollTop,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OpenTabsTableOrderingComposer
    extends Composer<_$AppDatabase, $OpenTabsTable> {
  $$OpenTabsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get selectionAnchor => $composableBuilder(
    column: $table.selectionAnchor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get selectionHead => $composableBuilder(
    column: $table.selectionHead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get scrollTop => $composableBuilder(
    column: $table.scrollTop,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OpenTabsTableAnnotationComposer
    extends Composer<_$AppDatabase, $OpenTabsTable> {
  $$OpenTabsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<bool> get active =>
      $composableBuilder(column: $table.active, builder: (column) => column);

  GeneratedColumn<int> get selectionAnchor => $composableBuilder(
    column: $table.selectionAnchor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get selectionHead => $composableBuilder(
    column: $table.selectionHead,
    builder: (column) => column,
  );

  GeneratedColumn<double> get scrollTop =>
      $composableBuilder(column: $table.scrollTop, builder: (column) => column);
}

class $$OpenTabsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OpenTabsTable,
          OpenTabRow,
          $$OpenTabsTableFilterComposer,
          $$OpenTabsTableOrderingComposer,
          $$OpenTabsTableAnnotationComposer,
          $$OpenTabsTableCreateCompanionBuilder,
          $$OpenTabsTableUpdateCompanionBuilder,
          (
            OpenTabRow,
            BaseReferences<_$AppDatabase, $OpenTabsTable, OpenTabRow>,
          ),
          OpenTabRow,
          PrefetchHooks Function()
        > {
  $$OpenTabsTableTableManager(_$AppDatabase db, $OpenTabsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OpenTabsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OpenTabsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OpenTabsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> workspaceId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<bool> active = const Value.absent(),
                Value<int?> selectionAnchor = const Value.absent(),
                Value<int?> selectionHead = const Value.absent(),
                Value<double> scrollTop = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OpenTabsCompanion(
                workspaceId: workspaceId,
                path: path,
                position: position,
                active: active,
                selectionAnchor: selectionAnchor,
                selectionHead: selectionHead,
                scrollTop: scrollTop,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String workspaceId,
                required String path,
                required int position,
                Value<bool> active = const Value.absent(),
                Value<int?> selectionAnchor = const Value.absent(),
                Value<int?> selectionHead = const Value.absent(),
                Value<double> scrollTop = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OpenTabsCompanion.insert(
                workspaceId: workspaceId,
                path: path,
                position: position,
                active: active,
                selectionAnchor: selectionAnchor,
                selectionHead: selectionHead,
                scrollTop: scrollTop,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OpenTabsTable, OpenTabRow>(table),
                  BaseReferences<_$AppDatabase, $OpenTabsTable, OpenTabRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OpenTabsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OpenTabsTable,
      OpenTabRow,
      $$OpenTabsTableFilterComposer,
      $$OpenTabsTableOrderingComposer,
      $$OpenTabsTableAnnotationComposer,
      $$OpenTabsTableCreateCompanionBuilder,
      $$OpenTabsTableUpdateCompanionBuilder,
      (OpenTabRow, BaseReferences<_$AppDatabase, $OpenTabsTable, OpenTabRow>),
      OpenTabRow,
      PrefetchHooks Function()
    >;
typedef $$JournalDocumentsTableCreateCompanionBuilder =
    JournalDocumentsCompanion Function({
      required String workspaceId,
      required String path,
      required String snapshotText,
      required int snapshotVersion,
      Value<String?> baseDigest,
      required String lineEnding,
      required bool bom,
      required String language,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$JournalDocumentsTableUpdateCompanionBuilder =
    JournalDocumentsCompanion Function({
      Value<String> workspaceId,
      Value<String> path,
      Value<String> snapshotText,
      Value<int> snapshotVersion,
      Value<String?> baseDigest,
      Value<String> lineEnding,
      Value<bool> bom,
      Value<String> language,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$JournalDocumentsTableFilterComposer
    extends Composer<_$AppDatabase, $JournalDocumentsTable> {
  $$JournalDocumentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get snapshotText => $composableBuilder(
    column: $table.snapshotText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get snapshotVersion => $composableBuilder(
    column: $table.snapshotVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseDigest => $composableBuilder(
    column: $table.baseDigest,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lineEnding => $composableBuilder(
    column: $table.lineEnding,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get bom => $composableBuilder(
    column: $table.bom,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JournalDocumentsTableOrderingComposer
    extends Composer<_$AppDatabase, $JournalDocumentsTable> {
  $$JournalDocumentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get snapshotText => $composableBuilder(
    column: $table.snapshotText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get snapshotVersion => $composableBuilder(
    column: $table.snapshotVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseDigest => $composableBuilder(
    column: $table.baseDigest,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lineEnding => $composableBuilder(
    column: $table.lineEnding,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get bom => $composableBuilder(
    column: $table.bom,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JournalDocumentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $JournalDocumentsTable> {
  $$JournalDocumentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get snapshotText => $composableBuilder(
    column: $table.snapshotText,
    builder: (column) => column,
  );

  GeneratedColumn<int> get snapshotVersion => $composableBuilder(
    column: $table.snapshotVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseDigest => $composableBuilder(
    column: $table.baseDigest,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lineEnding => $composableBuilder(
    column: $table.lineEnding,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get bom =>
      $composableBuilder(column: $table.bom, builder: (column) => column);

  GeneratedColumn<String> get language =>
      $composableBuilder(column: $table.language, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$JournalDocumentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $JournalDocumentsTable,
          JournalDocumentRow,
          $$JournalDocumentsTableFilterComposer,
          $$JournalDocumentsTableOrderingComposer,
          $$JournalDocumentsTableAnnotationComposer,
          $$JournalDocumentsTableCreateCompanionBuilder,
          $$JournalDocumentsTableUpdateCompanionBuilder,
          (
            JournalDocumentRow,
            BaseReferences<
              _$AppDatabase,
              $JournalDocumentsTable,
              JournalDocumentRow
            >,
          ),
          JournalDocumentRow,
          PrefetchHooks Function()
        > {
  $$JournalDocumentsTableTableManager(
    _$AppDatabase db,
    $JournalDocumentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JournalDocumentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JournalDocumentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$JournalDocumentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> workspaceId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> snapshotText = const Value.absent(),
                Value<int> snapshotVersion = const Value.absent(),
                Value<String?> baseDigest = const Value.absent(),
                Value<String> lineEnding = const Value.absent(),
                Value<bool> bom = const Value.absent(),
                Value<String> language = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => JournalDocumentsCompanion(
                workspaceId: workspaceId,
                path: path,
                snapshotText: snapshotText,
                snapshotVersion: snapshotVersion,
                baseDigest: baseDigest,
                lineEnding: lineEnding,
                bom: bom,
                language: language,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String workspaceId,
                required String path,
                required String snapshotText,
                required int snapshotVersion,
                Value<String?> baseDigest = const Value.absent(),
                required String lineEnding,
                required bool bom,
                required String language,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => JournalDocumentsCompanion.insert(
                workspaceId: workspaceId,
                path: path,
                snapshotText: snapshotText,
                snapshotVersion: snapshotVersion,
                baseDigest: baseDigest,
                lineEnding: lineEnding,
                bom: bom,
                language: language,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$JournalDocumentsTable, JournalDocumentRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $JournalDocumentsTable,
                    JournalDocumentRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$JournalDocumentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $JournalDocumentsTable,
      JournalDocumentRow,
      $$JournalDocumentsTableFilterComposer,
      $$JournalDocumentsTableOrderingComposer,
      $$JournalDocumentsTableAnnotationComposer,
      $$JournalDocumentsTableCreateCompanionBuilder,
      $$JournalDocumentsTableUpdateCompanionBuilder,
      (
        JournalDocumentRow,
        BaseReferences<
          _$AppDatabase,
          $JournalDocumentsTable,
          JournalDocumentRow
        >,
      ),
      JournalDocumentRow,
      PrefetchHooks Function()
    >;
typedef $$JournalChangesTableCreateCompanionBuilder =
    JournalChangesCompanion Function({
      Value<int> id,
      required String workspaceId,
      required String path,
      required int baseVersion,
      required int version,
      required int lengthBefore,
      required int lengthAfter,
      required String changes,
    });
typedef $$JournalChangesTableUpdateCompanionBuilder =
    JournalChangesCompanion Function({
      Value<int> id,
      Value<String> workspaceId,
      Value<String> path,
      Value<int> baseVersion,
      Value<int> version,
      Value<int> lengthBefore,
      Value<int> lengthAfter,
      Value<String> changes,
    });

class $$JournalChangesTableFilterComposer
    extends Composer<_$AppDatabase, $JournalChangesTable> {
  $$JournalChangesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lengthBefore => $composableBuilder(
    column: $table.lengthBefore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lengthAfter => $composableBuilder(
    column: $table.lengthAfter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get changes => $composableBuilder(
    column: $table.changes,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JournalChangesTableOrderingComposer
    extends Composer<_$AppDatabase, $JournalChangesTable> {
  $$JournalChangesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lengthBefore => $composableBuilder(
    column: $table.lengthBefore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lengthAfter => $composableBuilder(
    column: $table.lengthAfter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get changes => $composableBuilder(
    column: $table.changes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JournalChangesTableAnnotationComposer
    extends Composer<_$AppDatabase, $JournalChangesTable> {
  $$JournalChangesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get baseVersion => $composableBuilder(
    column: $table.baseVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<int> get lengthBefore => $composableBuilder(
    column: $table.lengthBefore,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lengthAfter => $composableBuilder(
    column: $table.lengthAfter,
    builder: (column) => column,
  );

  GeneratedColumn<String> get changes =>
      $composableBuilder(column: $table.changes, builder: (column) => column);
}

class $$JournalChangesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $JournalChangesTable,
          JournalChangeRow,
          $$JournalChangesTableFilterComposer,
          $$JournalChangesTableOrderingComposer,
          $$JournalChangesTableAnnotationComposer,
          $$JournalChangesTableCreateCompanionBuilder,
          $$JournalChangesTableUpdateCompanionBuilder,
          (
            JournalChangeRow,
            BaseReferences<
              _$AppDatabase,
              $JournalChangesTable,
              JournalChangeRow
            >,
          ),
          JournalChangeRow,
          PrefetchHooks Function()
        > {
  $$JournalChangesTableTableManager(
    _$AppDatabase db,
    $JournalChangesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JournalChangesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JournalChangesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$JournalChangesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> workspaceId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> baseVersion = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> lengthBefore = const Value.absent(),
                Value<int> lengthAfter = const Value.absent(),
                Value<String> changes = const Value.absent(),
              }) => JournalChangesCompanion(
                id: id,
                workspaceId: workspaceId,
                path: path,
                baseVersion: baseVersion,
                version: version,
                lengthBefore: lengthBefore,
                lengthAfter: lengthAfter,
                changes: changes,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String workspaceId,
                required String path,
                required int baseVersion,
                required int version,
                required int lengthBefore,
                required int lengthAfter,
                required String changes,
              }) => JournalChangesCompanion.insert(
                id: id,
                workspaceId: workspaceId,
                path: path,
                baseVersion: baseVersion,
                version: version,
                lengthBefore: lengthBefore,
                lengthAfter: lengthAfter,
                changes: changes,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$JournalChangesTable, JournalChangeRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $JournalChangesTable,
                    JournalChangeRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$JournalChangesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $JournalChangesTable,
      JournalChangeRow,
      $$JournalChangesTableFilterComposer,
      $$JournalChangesTableOrderingComposer,
      $$JournalChangesTableAnnotationComposer,
      $$JournalChangesTableCreateCompanionBuilder,
      $$JournalChangesTableUpdateCompanionBuilder,
      (
        JournalChangeRow,
        BaseReferences<_$AppDatabase, $JournalChangesTable, JournalChangeRow>,
      ),
      JournalChangeRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$WorkspacesTableTableManager get workspaces =>
      $$WorkspacesTableTableManager(_db, _db.workspaces);
  $$OpenTabsTableTableManager get openTabs =>
      $$OpenTabsTableTableManager(_db, _db.openTabs);
  $$JournalDocumentsTableTableManager get journalDocuments =>
      $$JournalDocumentsTableTableManager(_db, _db.journalDocuments);
  $$JournalChangesTableTableManager get journalChanges =>
      $$JournalChangesTableTableManager(_db, _db.journalChanges);
}

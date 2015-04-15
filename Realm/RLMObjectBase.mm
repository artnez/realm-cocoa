////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMObject_Private.hpp"

#import "RLMAccessor.h"
#import "RLMArray.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

const NSUInteger RLMDescriptionMaxDepth = 5;

@implementation RLMObjectBase

// standalone init
- (instancetype)init {
    if (RLMSchema.sharedSchema) {
        RLMObjectSchema *objectSchema = [self.class sharedSchema];
        self = [self initWithRealm:nil schema:objectSchema];

        // set default values
        if (!objectSchema.isSwiftClass) {
            NSDictionary *dict = RLMDefaultValuesForObjectSchema(objectSchema);
            for (NSString *key in dict) {
                [self setValue:dict[key] forKey:key];
            }
        }

        // set standalone accessor class
        object_setClass(self, objectSchema.standaloneClass);
    }
    else {
        // if schema not initialized
        // this is only used for introspection
        self = [super init];
    }

    return self;
}

- (instancetype)initWithObject:(id)value schema:(RLMSchema *)schema {
    self = [self init];
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        // validate and populate
        array = RLMValidatedArrayForObjectSchema(array, _objectSchema, schema);
        NSArray *properties = _objectSchema.properties;
        for (NSUInteger i = 0; i < array.count; i++) {
            [self setValue:array[i] forKeyPath:[properties[i] name]];
        }
    }
    else {
        // assume our object is an NSDictionary or a an object with kvc properties
        NSDictionary *dict = RLMValidatedDictionaryForObjectSchema(value, _objectSchema, schema);
        for (NSString *name in dict) {
            id val = dict[name];
            // strip out NSNull before passing values to standalone setters
            if (val == NSNull.null) {
                val = nil;
            }
            [self setValue:val forKeyPath:name];
        }
    }

    return self;
}

- (instancetype)initWithRealm:(__unsafe_unretained RLMRealm *const)realm
                       schema:(__unsafe_unretained RLMObjectSchema *const)schema {
    self = [super init];
    if (self) {
        _realm = realm;
        _objectSchema = schema;
    }
    return self;
}

// overridden at runtime per-class for performance
+ (NSString *)className {
    NSString *className = NSStringFromClass(self);
    if ([RLMSwiftSupport isSwiftClassName:className]) {
        className = [RLMSwiftSupport demangleClassName:className];
    }
    return className;
}

// overridden at runtime per-class for performance
+ (RLMObjectSchema *)sharedSchema {
    return RLMSchema.sharedSchema[self.className];
}

- (NSString *)description
{
    if (self.isInvalidated) {
        return @"[invalid object]";
    }

    return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    NSString *baseClassName = _objectSchema.className;
    NSMutableString *mString = [NSMutableString stringWithFormat:@"%@ {\n", baseClassName];

    for (RLMProperty *property in _objectSchema.properties) {
        id object = RLMObjectBaseObjectForKeyedSubscript(self, property.name);
        NSString *sub;
        if ([object respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [object descriptionWithMaxDepth:depth - 1];
        }
        else if (property.type == RLMPropertyTypeData) {
            static NSUInteger maxPrintedDataLength = 24;
            NSData *data = object;
            NSUInteger length = data.length;
            if (length > maxPrintedDataLength) {
                data = [NSData dataWithBytes:data.bytes length:maxPrintedDataLength];
            }
            NSString *dataDescription = [data description];
            sub = [NSString stringWithFormat:@"<%@ — %lu total bytes>", [dataDescription substringWithRange:NSMakeRange(1, dataDescription.length - 2)], (unsigned long)length];
        }
        else {
            sub = [object description];
        }
        [mString appendFormat:@"\t%@ = %@;\n", property.name, [sub stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    [mString appendString:@"}"];

    return [NSString stringWithString:mString];
}

- (BOOL)isInvalidated {
    // if not standalone and our accessor has been detached, we have been deleted
    return self.class == _objectSchema.accessorClass && !_row.is_attached();
}

- (BOOL)isDeletedFromRealm {
    return self.isInvalidated;
}

- (BOOL)isEqual:(id)object {
    if (RLMObjectBase *other = RLMDynamicCast<RLMObjectBase>(object)) {
        if (_objectSchema.primaryKeyProperty) {
            return RLMObjectBaseAreEqual(self, other);
        }
    }
    return [super isEqual:object];
}

- (NSUInteger)hash {
    if (_objectSchema.primaryKeyProperty) {
        id primaryProperty = [self valueForKey:_objectSchema.primaryKeyProperty.name];

        // modify the hash of our primary key value to avoid potential (although unlikely) collisions
        return [primaryProperty hash] ^ 1;
    }
    else {
        return [super hash];
    }
}

- (id)mutableArrayValueForKey:(NSString *)key {
    id obj = [self valueForKey:key];
    if ([obj isKindOfClass:[RLMArray class]]) {
        return obj;
    }
    return [super mutableArrayValueForKey:key];
}

- (void)addObserver:(id)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context {
    if (!_objectSchema[keyPath]) {
        // FIXME: standalone needs to record/reregister
        return [super addObserver:observer forKeyPath:keyPath options:options context:context];
    }

    if (!_objectSchema->_observers) {
        _objectSchema->_observers = [NSMutableDictionary new];
    }

    NSMutableArray *observers = _objectSchema->_observers[keyPath];
    if (!observers) {
        observers = [NSMutableArray new];
        _objectSchema->_observers[keyPath] = observers;
    }

    RLMObservationInfo *info = [RLMObservationInfo new];
    info.observer = observer;
    info.options = options;
    info.context = context;
    info.obj = self;
    info.key = keyPath;
    info.column = _objectSchema[keyPath].column;
    [observers addObject:info];

    if (options & NSKeyValueObservingOptionOld) {
        info.oldValue = [self valueForKey:keyPath];
    }
    if (options & NSKeyValueObservingOptionInitial) {
        [observer observeValueForKeyPath:keyPath ofObject:self change:nil context:context];
    }
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath {
    NSMutableArray *observers = _objectSchema->_observers[keyPath];
    for (RLMObservationInfo *info in observers) {
        if (info.observer == observer) {
            [observers removeObject:info];
            return;
        }
    }

    [super removeObserver:observer forKeyPath:keyPath];
}

- (void)willChangeValueForKey:(NSString *)key {
    if (!_objectSchema[key]) {
        return [super willChangeValueForKey:key];
    }

    for (RLMObservationInfo *info in _objectSchema->_observers[key]) {
        if (info.obj->_row.get_index() == _row.get_index()) {
            RLMWillChange(info, key);
        }
    }
}

- (void)didChangeValueForKey:(NSString *)key {
    if (!_objectSchema[key]) {
        return [super didChangeValueForKey:key];
    }

    id value = [self valueForKey:key];

    for (RLMObservationInfo *info in _objectSchema->_observers[key]) {
        if (info.obj->_row.get_index() != _row.get_index()) {
            continue;
        }

        RLMDidChange(info, key, value);
    }
}

- (void)willChange:(NSKeyValueChange)changeKind valuesAtIndexes:(NSIndexSet *)indexes forKey:(NSString *)key {
    for (RLMObservationInfo *info in _objectSchema->_observers[key]) {
        if (info.obj->_row.get_index() == _row.get_index()) {
            RLMWillChange(info, key, changeKind, indexes);
        }
    }
}

- (void)didChange:(NSKeyValueChange)changeKind valuesAtIndexes:(NSIndexSet *)indexes forKey:(NSString *)key {
    id value = [self valueForKey:key];

    for (RLMObservationInfo *info in _objectSchema->_observers[key]) {
        if (info.obj->_row.get_index() != _row.get_index()) {
            continue;
        }

        RLMDidChange(info, key, value, changeKind, indexes);
    }
}

@end

void RLMWillChange(RLMObservationInfo *info, NSString *key, NSKeyValueChange kind, NSIndexSet *is) {
    if (info.options & NSKeyValueObservingOptionPrior) {
        NSMutableDictionary *change = [NSMutableDictionary new];
        change[NSKeyValueChangeKindKey] = @(kind);
        if (info.options & NSKeyValueObservingOptionOld)
            change[NSKeyValueChangeOldKey] = info.oldValue;
        if (is)
            change[NSKeyValueChangeIndexesKey] = is;
        change[NSKeyValueChangeNotificationIsPriorKey] = @YES;
        [info.observer observeValueForKeyPath:key ofObject:info.obj change:change context:info.context];
    }
}

void RLMDidChange(RLMObservationInfo *info, NSString *key, id value, NSKeyValueChange kind, NSIndexSet *is) {
    NSMutableDictionary *change = [NSMutableDictionary new];
    change[NSKeyValueChangeKindKey] = @(kind);
    if (info.options & NSKeyValueObservingOptionOld)
        change[NSKeyValueChangeOldKey] = info.oldValue ?: NSNull.null;
    if (info.options & NSKeyValueObservingOptionNew)
        change[NSKeyValueChangeNewKey] = value ?: NSNull.null;
    if (is)
        change[NSKeyValueChangeIndexesKey] = is;
    [info.observer observeValueForKeyPath:key ofObject:info.obj change:change context:info.context];
    if (info.options & NSKeyValueObservingOptionOld) {
        info.oldValue = value;
    }
}

@implementation RLMObservationInfo
@end

void RLMObjectBaseSetRealm(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMRealm *realm) {
    if (object) {
        object->_realm = realm;
    }
}

RLMRealm *RLMObjectBaseRealm(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_realm : nil;
}

void RLMObjectBaseSetObjectSchema(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMObjectSchema *objectSchema) {
    if (object) {
        object->_objectSchema = objectSchema;
    }
}

RLMObjectSchema *RLMObjectBaseObjectSchema(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_objectSchema : nil;
}

NSArray *RLMObjectBaseLinkingObjectsOfClass(RLMObjectBase *object, NSString *className, NSString *property) {
    if (!object) {
        return nil;
    }

    if (!object->_realm) {
        @throw RLMException(@"Linking object only available for objects in a Realm.");
    }
    RLMCheckThread(object->_realm);

    if (!object->_row.is_attached()) {
        @throw RLMException(@"Object has been deleted or invalidated and is no longer valid.");
    }

    RLMObjectSchema *schema = object->_realm.schema[className];
    RLMProperty *prop = schema[property];
    if (!prop) {
        @throw RLMException([NSString stringWithFormat:@"Invalid property '%@'", property]);
    }

    if (![prop.objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException([NSString stringWithFormat:@"Property '%@' of '%@' expected to be an RLMObject or RLMArray property pointing to type '%@'", property, className, object->_objectSchema.className]);
    }

    Table *table = schema.table;
    if (!table) {
        return @[];
    }

    size_t col = prop.column;
    NSUInteger count = object->_row.get_backlink_count(*table, col);
    NSMutableArray *links = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [links addObject:RLMCreateObjectAccessor(object->_realm, schema, object->_row.get_backlink(*table, col, i))];
    }
    return [links copy];
}

id RLMObjectBaseObjectForKeyedSubscript(RLMObjectBase *object, NSString *key) {
    if (!object) {
        return nil;
    }

    if (object->_realm) {
        return RLMDynamicGet(object, key);
    }
    else {
        return [object valueForKey:key];
    }
}

void RLMObjectBaseSetObjectForKeyedSubscript(RLMObjectBase *object, NSString *key, id obj) {
    if (!object) {
        return;
    }

    if (object->_realm) {
        RLMDynamicValidatedSet(object, key, obj);
    }
    else {
        [object setValue:obj forKey:key];
    }
}


BOOL RLMObjectBaseAreEqual(RLMObjectBase *o1, RLMObjectBase *o2) {
    // if not the correct types throw
    if ((o1 && ![o1 isKindOfClass:RLMObjectBase.class]) || (o2 && ![o2 isKindOfClass:RLMObjectBase.class])) {
        @throw RLMException(@"Can only compare objects of class RLMObjectBase");
    }
    // if identical object (or both are nil)
    if (o1 == o2) {
        return YES;
    }
    // if one is nil
    if (o1 == nil || o2 == nil) {
        return NO;
    }
    // if not in realm or differing realms
    if (o1->_realm == nil || o1->_realm != o2->_realm) {
        return NO;
    }
    // if either are detached
    if (!o1->_row.is_attached() || !o2->_row.is_attached()) {
        return NO;
    }
    // if table and index are the same
    return o1->_row.get_table() == o2->_row.get_table() &&
    o1->_row.get_index() == o2->_row.get_index();
}


Class RLMObjectUtilClass(BOOL isSwift) {
    static Class objectUtilObjc = [RLMObjectUtil class];
    static Class objectUtilSwift = NSClassFromString(@"RealmSwift.ObjectUtil");
    return isSwift && objectUtilSwift ? objectUtilSwift : objectUtilObjc;
}

@implementation RLMObjectUtil

+ (NSString *)primaryKeyForClass:(Class)cls {
    return [cls primaryKey];
}

+ (NSArray *)ignoredPropertiesForClass:(Class)cls {
    return [cls ignoredProperties];
}

+ (NSArray *)indexedPropertiesForClass:(Class)cls {
    return [cls indexedProperties];
}

+ (NSArray *)getGenericListPropertyNames:(__unused id)obj {
    return nil;
}

+ (void)initializeListProperty:(__unused RLMObjectBase *)object property:(__unused RLMProperty *)property array:(__unused RLMArray *)array {
}

@end

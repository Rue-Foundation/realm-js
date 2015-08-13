//
//  RJSObject.m
//  RealmJS
//
//  Created by Ari Lazier on 5/5/15.
//  Copyright (c) 2015 Realm. All rights reserved.
//

#import "RJSUtil.hpp"
#import "RJSObject.hpp"
#import "RJSResults.hpp"
#import "RJSSchema.hpp"
#import "RJSArray.hpp"

#import "object_store.hpp"
#import "object_accessor.hpp"

using namespace realm;
using RJSAccessor = NativeAccessor<JSValueRef, JSContextRef>;

JSValueRef ObjectGetProperty(JSContextRef ctx, JSObjectRef jsObject, JSStringRef jsPropertyName, JSValueRef* exception) {
    Object *obj = RJSGetInternal<Object *>(jsObject);

    std::string propName = RJSStringForJSString(jsPropertyName);
    ObjectSchema &objectSchema = obj->object_schema;
    Property *prop = objectSchema.property_for_name(propName);
    if (!prop) {
        return NULL;
    }

    switch (prop->type) {
        case PropertyTypeBool:
            return JSValueMakeBoolean(ctx, obj->row.get_bool(prop->table_column));
        case PropertyTypeInt:
            return JSValueMakeNumber(ctx, obj->row.get_int(prop->table_column));
        case PropertyTypeFloat:
            return JSValueMakeNumber(ctx, obj->row.get_float(prop->table_column));
        case PropertyTypeDouble:
            return JSValueMakeNumber(ctx, obj->row.get_double(prop->table_column));
        case PropertyTypeString:
            return RJSValueForString(ctx, obj->row.get_string(prop->table_column));
        case PropertyTypeData:
            return RJSValueForString(ctx, (std::string)obj->row.get_binary(prop->table_column));
        case PropertyTypeAny:
            *exception = RJSMakeError(ctx, "'Any' type not supported");
            return NULL;
        case PropertyTypeDate: {
            JSValueRef time = JSValueMakeNumber(ctx, obj->row.get_datetime(prop->table_column).get_datetime());
            return JSObjectMakeDate(ctx, 1, &time, exception);
        }
        case PropertyTypeObject: {
            ObjectSchema &linkObjectSchema = obj->realm->config().schema->at(prop->object_type);
            TableRef table = ObjectStore::table_for_object_type(obj->realm->read_group(), linkObjectSchema.name);
            if (obj->row.is_null_link(prop->table_column)) {
                return JSValueMakeNull(ctx);
            }
            return RJSObjectCreate(ctx, Object(obj->realm, linkObjectSchema, table->get(obj->row.get_link(prop->table_column))));
        }
        case PropertyTypeArray: {
            ObjectSchema &arrayObjectSchema = obj->realm->config().schema->at(prop->object_type);
            return RJSArrayCreate(ctx, new ObjectArray(obj->realm, arrayObjectSchema, static_cast<LinkViewRef>(obj->row.get_linklist(prop->table_column))));
        }

    }
    return NULL;
}

bool ObjectSetProperty(JSContextRef ctx, JSObjectRef jsObject, JSStringRef jsPropertyName, JSValueRef value, JSValueRef* exception) {
    try {
        Object *obj = RJSGetInternal<Object *>(jsObject);
        obj->set_property_value(ctx, RJSStringForJSString(jsPropertyName), value, true);
    } catch (std::exception &ex) {
        if (*exception) {
            *exception = RJSMakeError(ctx, ex);
        }
    }
    return true;
}

void ObjectPropertyNames(JSContextRef ctx, JSObjectRef object, JSPropertyNameAccumulatorRef propertyNames) {
    return;
}

JSClassRef RJSObjectClass() {
    static JSClassRef s_objectClass = RJSCreateWrapperClass<Object>("RealmObject", ObjectGetProperty, ObjectSetProperty, NULL, NULL, ObjectPropertyNames);
    return s_objectClass;
}

JSObjectRef RJSObjectCreate(JSContextRef ctx, Object object) {
    JSValueRef prototype = RJSPrototypeForClassName(object.object_schema.name);
    JSObjectRef jsObject = RJSWrapObject(ctx, RJSObjectClass(), new Object(object), prototype);
    return jsObject;
}

template<> JSValueRef RJSAccessor::dict_value_for_key(JSContextRef ctx, JSValueRef dict, const std::string &prop_name) {
    JSObjectRef object = RJSValidatedValueToObject(ctx, dict);
    JSStringRef propStr =JSStringCreateWithUTF8CString(prop_name.c_str());
    JSValueRef ex = NULL;
    JSValueRef ret = JSObjectGetProperty(ctx, object, propStr, &ex);
    if (ex) {
        throw RJSException(ctx, ex);
    }
    JSStringRelease(propStr);
    return ret;
}

template<> bool RJSAccessor::is_null(JSContextRef ctx, JSValueRef &val) {
    return JSValueIsUndefined(ctx, val) || JSValueIsNull(ctx, val);
}

template<> bool RJSAccessor::to_bool(JSContextRef ctx, JSValueRef &val) {
    if (!JSValueIsBoolean(ctx, val)) {
        throw std::runtime_error("Property expected to be of type boolean");
    }
    return JSValueToBoolean(ctx, val);
}

template<> long long RJSAccessor::to_long(JSContextRef ctx, JSValueRef &val) {
    return RJSValidatedValueToNumber(ctx, val);
}

template<> float RJSAccessor::to_float(JSContextRef ctx, JSValueRef &val) {
    return RJSValidatedValueToNumber(ctx, val);
}

template<> double RJSAccessor::to_double(JSContextRef ctx, JSValueRef &val) {
    return RJSValidatedValueToNumber(ctx, val);
}

template<> std::string RJSAccessor::to_string(JSContextRef ctx, JSValueRef &val) {
    return RJSValidatedStringForValue(ctx, val);
}

template<> DateTime RJSAccessor::to_datetime(JSContextRef ctx, JSValueRef &val) {
    JSObjectRef object = RJSValidatedValueToObject(ctx, val, "Property must be a Date");

    JSValueRef exception = NULL;
    static JSStringRef utcString = JSStringCreateWithUTF8CString("getTime");
    JSObjectRef utcGetter = RJSValidatedObjectProperty(ctx, object, utcString);

    JSValueRef utcVal = JSObjectCallAsFunction(ctx, utcGetter, object, 0, NULL, &exception);
    if (exception) {
        throw RJSException(ctx, exception);
    }

    double utc = JSValueToNumber(ctx, utcVal, &exception);
    if (exception) {
        throw RJSException(ctx, exception);
    }

    return DateTime(utc);
}

extern JSObjectRef RJSDictForPropertyArray(JSContextRef ctx, ObjectSchema &object_schema, JSObjectRef array);

template<> size_t RJSAccessor::to_object_index(JSContextRef ctx, SharedRealm &realm, JSValueRef &val, Property &prop, bool try_update) {
    JSObjectRef object = RJSValidatedValueToObject(ctx, val);
    if (JSValueIsObjectOfClass(ctx, val, RJSObjectClass())) {
        return RJSGetInternal<Object *>(object)->row.get_index();
    }

    static JSStringRef arrayString = JSStringCreateWithUTF8CString("Array");
    ObjectSchema &object_schema = realm->config().schema->at(prop.object_type);
    if (RJSIsValueObjectOfType(ctx, object, arrayString)) {
        object = RJSDictForPropertyArray(ctx, object_schema, object);
    }

    Object child = Object::create<JSValueRef>(ctx, realm, object_schema, (JSValueRef)object, try_update);
    return child.row.get_index();
}

template<> size_t RJSAccessor::array_size(JSContextRef ctx, JSValueRef &val) {
    return RJSValidatedArrayLength(ctx, RJSValidatedValueToObject(ctx, val));
}

template<> JSValueRef RJSAccessor::array_value_at_index(JSContextRef ctx, JSValueRef &val, size_t index) {
    return RJSValidatedObjectAtIndex(ctx, RJSValidatedValueToObject(ctx, val), (unsigned int)index);
}
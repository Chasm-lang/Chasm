#pragma once
/* chasm_gde_types.h — Minimal GDExtension type definitions.
 *
 * This is a hand-curated subset of Godot's gdextension_interface.h covering
 * exactly what ChasmComponent needs. Targets Godot 4.2+.
 *
 * If you have the full Godot headers, replace this include with:
 *   #include <godot/gdextension_interface.h>
 */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* ---- Primitive types -------------------------------------------------- */

typedef uint8_t  GDExtensionBool;
typedef int64_t  GDExtensionInt;
typedef float    GDExtensionFloat;

#define GDEXTENSION_TRUE  1
#define GDEXTENSION_FALSE 0

/* Opaque pointer types. Each represents a Godot value in memory. */
typedef void *GDExtensionObjectPtr;
typedef void *GDExtensionClassInstancePtr;
typedef void *GDExtensionClassLibraryPtr;
typedef void *GDExtensionTypePtr;
typedef void *GDExtensionVariantPtr;
typedef void *GDExtensionStringPtr;
typedef void *GDExtensionStringNamePtr;
typedef void *GDExtensionUninitializedTypePtr;
typedef void *GDExtensionUninitializedStringPtr;
typedef void *GDExtensionUninitializedStringNamePtr;
typedef void *GDExtensionUninitializedVariantPtr;
typedef const void *GDExtensionConstTypePtr;
typedef const void *GDExtensionConstVariantPtr;
typedef const void *GDExtensionConstStringPtr;
typedef const void *GDExtensionConstStringNamePtr;
typedef const void *GDExtensionConstObjectPtr;

/* ---- Variant type enum ----------------------------------------------- */
typedef enum {
    GDEXTENSION_VARIANT_TYPE_NIL = 0,
    GDEXTENSION_VARIANT_TYPE_BOOL,
    GDEXTENSION_VARIANT_TYPE_INT,
    GDEXTENSION_VARIANT_TYPE_FLOAT,
    GDEXTENSION_VARIANT_TYPE_STRING,
    GDEXTENSION_VARIANT_TYPE_VECTOR2,
    GDEXTENSION_VARIANT_TYPE_VECTOR2I,
    GDEXTENSION_VARIANT_TYPE_RECT2,
    GDEXTENSION_VARIANT_TYPE_RECT2I,
    GDEXTENSION_VARIANT_TYPE_VECTOR3,
    GDEXTENSION_VARIANT_TYPE_VECTOR3I,
    GDEXTENSION_VARIANT_TYPE_TRANSFORM2D,
    GDEXTENSION_VARIANT_TYPE_VECTOR4,
    GDEXTENSION_VARIANT_TYPE_VECTOR4I,
    GDEXTENSION_VARIANT_TYPE_PLANE,
    GDEXTENSION_VARIANT_TYPE_QUATERNION,
    GDEXTENSION_VARIANT_TYPE_AABB,
    GDEXTENSION_VARIANT_TYPE_BASIS,
    GDEXTENSION_VARIANT_TYPE_TRANSFORM3D,
    GDEXTENSION_VARIANT_TYPE_PROJECTION,
    GDEXTENSION_VARIANT_TYPE_COLOR,
    GDEXTENSION_VARIANT_TYPE_STRING_NAME,
    GDEXTENSION_VARIANT_TYPE_NODE_PATH,
    GDEXTENSION_VARIANT_TYPE_RID,
    GDEXTENSION_VARIANT_TYPE_OBJECT,
    GDEXTENSION_VARIANT_TYPE_CALLABLE,
    GDEXTENSION_VARIANT_TYPE_SIGNAL,
    GDEXTENSION_VARIANT_TYPE_DICTIONARY,
    GDEXTENSION_VARIANT_TYPE_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_INT32_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_INT64_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_STRING_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR3_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_COLOR_ARRAY,
    GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR4_ARRAY,
    GDEXTENSION_VARIANT_TYPE_MAX,
} GDExtensionVariantType;

/* ---- Call error -------------------------------------------------------- */
typedef enum {
    GDEXTENSION_CALL_OK,
    GDEXTENSION_CALL_ERROR_INVALID_METHOD,
    GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT,
    GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS,
    GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS,
    GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL,
    GDEXTENSION_CALL_ERROR_METHOD_NOT_CONST,
    GDEXTENSION_CALL_MAX,
} GDExtensionCallErrorType;

typedef struct {
    GDExtensionCallErrorType error;
    int32_t argument;
    int32_t expected;
} GDExtensionCallError;

/* ---- Initialization --------------------------------------------------- */
typedef enum {
    GDEXTENSION_INITIALIZATION_CORE = 0,
    GDEXTENSION_INITIALIZATION_SERVERS,
    GDEXTENSION_INITIALIZATION_SCENE,
    GDEXTENSION_INITIALIZATION_EDITOR,
    GDEXTENSION_MAX_INITIALIZATION_LEVEL,
} GDExtensionInitializationLevel;

typedef struct {
    GDExtensionInitializationLevel minimum_initialization_level;
    void *userdata;
    void (*initialize)  (void *userdata, GDExtensionInitializationLevel p_level);
    void (*deinitialize)(void *userdata, GDExtensionInitializationLevel p_level);
} GDExtensionInitialization;

/* ---- Method flags ----------------------------------------------------- */
#define GDEXTENSION_METHOD_FLAG_NORMAL        1
#define GDEXTENSION_METHOD_FLAG_EDITOR        2
#define GDEXTENSION_METHOD_FLAG_CONST         4
#define GDEXTENSION_METHOD_FLAG_VIRTUAL       8
#define GDEXTENSION_METHOD_FLAG_VARARG       16
#define GDEXTENSION_METHOD_FLAG_STATIC       32
#define GDEXTENSION_METHOD_FLAGS_DEFAULT GDEXTENSION_METHOD_FLAG_NORMAL

/* ---- Property flags --------------------------------------------------- */
#define GDEXTENSION_PROPERTY_HINT_NONE       0
#define GDEXTENSION_PROPERTY_HINT_GLOBAL_FILE 21
#define GDEXTENSION_PROPERTY_USAGE_NONE      0
#define GDEXTENSION_PROPERTY_USAGE_STORAGE   2
#define GDEXTENSION_PROPERTY_USAGE_EDITOR    4
#define GDEXTENSION_PROPERTY_USAGE_DEFAULT   6

/* ---- Property and method info ----------------------------------------- */
typedef struct {
    GDExtensionVariantType      type;
    GDExtensionStringNamePtr    class_name;
    GDExtensionStringNamePtr    name;
    GDExtensionStringPtr        hint_string;
    uint32_t                    hint;
    uint32_t                    usage;
} GDExtensionPropertyInfo;

typedef int32_t GDExtensionClassMethodArgumentMetadata;
#define GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE 0

typedef void (*GDExtensionInterfaceFunction)(void);
typedef GDExtensionInterfaceFunction (*GDExtensionInterfaceGetProcAddress)(const char *p_function_name);

/* ---- Class method callbacks ------------------------------------------- */
typedef void (*GDExtensionClassMethodCall)(
    void *method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionVariantPtr *p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError *r_error
);
typedef void (*GDExtensionClassMethodPtrCall)(
    void *method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret
);

typedef struct {
    GDExtensionStringNamePtr                    name;
    void                                       *method_userdata;
    GDExtensionClassMethodCall                  call_func;
    GDExtensionClassMethodPtrCall               ptrcall_func;
    uint32_t                                    method_flags;
    GDExtensionBool                             has_return_value;
    GDExtensionPropertyInfo                    *return_value_info;
    GDExtensionClassMethodArgumentMetadata      return_value_metadata;
    uint32_t                                    argument_count;
    GDExtensionPropertyInfo                    *arguments_info;
    GDExtensionClassMethodArgumentMetadata     *arguments_metadata;
    uint32_t                                    default_argument_count;
    GDExtensionVariantPtr                      *default_arguments;
} GDExtensionClassMethodInfo;

/* ---- Class creation info (GDE API v2, Godot 4.2+) -------------------- */
typedef void (*GDExtensionClassCallVirtual)(
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret
);
typedef GDExtensionClassCallVirtual (*GDExtensionClassGetVirtual)(
    void *p_userdata,
    GDExtensionConstStringNamePtr p_name
);
typedef GDExtensionObjectPtr (*GDExtensionClassCreateInstance2)(void *p_userdata);
typedef void (*GDExtensionClassFreeInstance)(
    void *p_userdata,
    GDExtensionClassInstancePtr p_instance
);
typedef GDExtensionClassInstancePtr (*GDExtensionClassRecreateInstance)(
    void *p_userdata,
    GDExtensionObjectPtr p_object
);

typedef GDExtensionBool (*GDExtensionClassSet)(
    GDExtensionClassInstancePtr p_instance,
    GDExtensionConstStringNamePtr p_name,
    GDExtensionConstVariantPtr p_value
);
typedef GDExtensionBool (*GDExtensionClassGet)(
    GDExtensionClassInstancePtr p_instance,
    GDExtensionConstStringNamePtr p_name,
    GDExtensionVariantPtr r_ret
);
typedef void (*GDExtensionClassNotification2)(
    GDExtensionClassInstancePtr p_instance,
    int32_t p_what,
    GDExtensionBool p_reversed
);
typedef void (*GDExtensionClassToString)(
    GDExtensionClassInstancePtr p_instance,
    GDExtensionBool *r_is_valid,
    GDExtensionStringPtr p_out
);

typedef struct {
    GDExtensionBool                     is_virtual;
    GDExtensionBool                     is_abstract;
    GDExtensionBool                     is_exposed;
    GDExtensionBool                     is_runtime;
    const char                         *p_native_structure_string;
    GDExtensionClassSet                 set_func;
    GDExtensionClassGet                 get_func;
    void                               *get_property_list_func;
    void                               *free_property_list_func;
    void                               *property_can_revert_func;
    void                               *property_get_revert_func;
    void                               *validate_property_func;
    GDExtensionClassNotification2       notification_func;
    GDExtensionClassToString            to_string_func;
    void                               *reference_func;
    void                               *unreference_func;
    GDExtensionClassCreateInstance2     create_instance_func;
    GDExtensionClassFreeInstance        free_instance_func;
    GDExtensionClassRecreateInstance    recreate_instance_func;
    GDExtensionClassGetVirtual          get_virtual_func;
    void                               *get_virtual_call_data_func;
    void                               *call_virtual_with_data_func;
    void                               *get_rid_func;
    void                               *class_userdata;
} GDExtensionClassCreationInfo2;

/* ---- GDExtension interface function pointer typedefs ----------------- */

/* String helpers */
typedef void (*GDExtensionInterfaceStringNameNewWithUtf8Chars)(
    GDExtensionUninitializedStringNamePtr r_dest,
    const char *p_contents,
    GDExtensionBool p_is_static
);
typedef void (*GDExtensionInterfaceStringNameDestroyType)(
    GDExtensionStringNamePtr p_self
);
typedef void (*GDExtensionInterfaceStringNewWithUtf8Chars)(
    GDExtensionUninitializedStringPtr r_dest,
    const char *p_contents
);
typedef void (*GDExtensionInterfaceStringDestroyType)(
    GDExtensionStringPtr p_self
);
typedef GDExtensionInt (*GDExtensionInterfaceStringToUtf8CharsType)(
    GDExtensionConstStringPtr p_self,
    char *r_text,
    GDExtensionInt p_max_write_length
);

/* Variant helpers */
typedef void (*GDExtensionInterfaceVariantNewCopyType)(
    GDExtensionUninitializedVariantPtr r_dest,
    GDExtensionConstVariantPtr p_src
);
typedef void (*GDExtensionInterfaceVariantDestroyType)(
    GDExtensionVariantPtr p_self
);
typedef GDExtensionVariantType (*GDExtensionInterfaceVariantGetTypeType)(
    GDExtensionConstVariantPtr p_self
);
typedef void (*GDExtensionInterfaceVariantStringifyType)(
    GDExtensionConstVariantPtr p_self,
    GDExtensionStringPtr r_str
);
/* Convert String Variant to String (for ptrcall String return) */
typedef void (*GDExtensionInterfaceVariantGetPtrType)(
    GDExtensionConstVariantPtr p_self,
    GDExtensionTypePtr r_ret,
    GDExtensionVariantType p_type
);

/* Object helpers */
typedef void (*GDExtensionInterfaceObjectSetInstanceType)(
    GDExtensionObjectPtr p_object,
    GDExtensionConstStringNamePtr p_classname,
    GDExtensionClassInstancePtr p_instance
);
typedef GDExtensionClassInstancePtr (*GDExtensionInterfaceObjectGetInstanceType)(
    GDExtensionConstObjectPtr p_object,
    GDExtensionConstStringNamePtr p_classname
);
typedef GDExtensionObjectPtr (*GDExtensionInterfaceClassdbConstructObjectType)(
    GDExtensionConstStringNamePtr p_classname
);
typedef void *(*GDExtensionInterfaceClassdbGetMethodBindType)(
    GDExtensionConstStringNamePtr p_classname,
    GDExtensionConstStringNamePtr p_methodname,
    GDExtensionInt p_hash
);
typedef void (*GDExtensionInterfaceObjectMethodBindPtrCallType)(
    void *p_method_bind,
    GDExtensionObjectPtr p_instance,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret
);

/* Class registration */
typedef void (*GDExtensionInterfaceClassdbRegisterExtensionClass2Type)(
    GDExtensionClassLibraryPtr p_library,
    GDExtensionConstStringNamePtr p_class_name,
    GDExtensionConstStringNamePtr p_parent_class_name,
    const GDExtensionClassCreationInfo2 *p_extension_funcs
);
typedef void (*GDExtensionInterfaceClassdbRegisterExtensionClassMethodType)(
    GDExtensionClassLibraryPtr p_library,
    GDExtensionConstStringNamePtr p_class_name,
    const GDExtensionClassMethodInfo *p_method_info
);
typedef void (*GDExtensionInterfaceClassdbRegisterExtensionClassPropertyType)(
    GDExtensionClassLibraryPtr p_library,
    GDExtensionConstStringNamePtr p_class_name,
    const GDExtensionPropertyInfo *p_info,
    GDExtensionConstStringNamePtr p_setter,
    GDExtensionConstStringNamePtr p_getter
);
typedef void (*GDExtensionInterfaceClassdbUnregisterExtensionClassType)(
    GDExtensionClassLibraryPtr p_library,
    GDExtensionConstStringNamePtr p_class_name
);

/* ---- Convenience macros ---------------------------------------------- */

/* Declare a static StringName buffer and fill it at runtime.
 * Use CHASM_SN_INIT(buf, "name") in the init function. */
#define CHASM_SN_DECL(var)       static uint8_t var[8]
#define CHASM_SN_INIT(gde_sn_new, var, str) \
    (gde_sn_new)((GDExtensionUninitializedStringNamePtr)(var), (str), GDEXTENSION_TRUE)

/* Declare a static String buffer and fill it at runtime. */
#define CHASM_STR_DECL(var)      static uint8_t var[8]
#define CHASM_STR_INIT(gde_str_new, var, str) \
    (gde_str_new)((GDExtensionUninitializedStringPtr)(var), (str))

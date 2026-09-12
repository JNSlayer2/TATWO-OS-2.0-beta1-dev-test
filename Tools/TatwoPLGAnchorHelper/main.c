#include <CommonCrypto/CommonHMAC.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *default_service =
    "ai.tatwo.ultrawork.plg-chain-anchor.production.v3";
static const char *default_account = "stable-helper-v1";
static const size_t maximum_material_bytes = 1024 * 1024;
static const size_t maximum_identity_bytes = 512;

static const char *configured_identity(
    const char *environment_name, const char *fallback) {
  const char *value = getenv(environment_name);
  if (value == NULL || value[0] == '\0') {
    return fallback;
  }
  if (strlen(value) > maximum_identity_bytes) {
    return NULL;
  }
  return value;
}

static CFMutableDictionaryRef base_query(void) {
  const char *service = configured_identity(
      "TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE", default_service);
  const char *account = configured_identity(
      "TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT", default_account);
  if (service == NULL || account == NULL) {
    return NULL;
  }
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFStringRef service_value =
      CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
  CFStringRef account_value =
      CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, service_value);
  CFDictionarySetValue(query, kSecAttrAccount, account_value);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CFDictionarySetValue(
      query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
#pragma clang diagnostic pop
  CFRelease(service_value);
  CFRelease(account_value);
  return query;
}

static OSStatus read_existing_key(unsigned char key[32]) {
  CFMutableDictionaryRef query = base_query();
  if (query == NULL) {
    return errSecParam;
  }
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);
  if (status != errSecSuccess) {
    return status;
  }
  CFDataRef data = (CFDataRef)result;
  if (CFDataGetLength(data) != 32) {
    CFRelease(result);
    return errSecDecode;
  }
  memcpy(key, CFDataGetBytePtr(data), 32);
  CFRelease(result);
  return errSecSuccess;
}

static OSStatus load_or_create_key(unsigned char key[32]) {
  OSStatus status = read_existing_key(key);
  if (status == errSecSuccess) {
    return status;
  }
  if (status != errSecItemNotFound) {
    return status;
  }
  status = SecRandomCopyBytes(kSecRandomDefault, 32, key);
  if (status != errSecSuccess) {
    return status;
  }
  CFMutableDictionaryRef add = base_query();
  if (add == NULL) {
    return errSecParam;
  }
  CFDataRef data = CFDataCreate(NULL, key, 32);
  CFDictionarySetValue(add, kSecValueData, data);
  CFDictionarySetValue(
      add, kSecAttrAccessible,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
  CFRelease(data);
  status = SecItemAdd(add, NULL);
  CFRelease(add);
  if (status == errSecDuplicateItem) {
    return read_existing_key(key);
  }
  return status;
}

static int read_material(unsigned char **buffer, size_t *length) {
  size_t capacity = 4096;
  unsigned char *bytes = malloc(capacity);
  if (bytes == NULL) {
    return 1;
  }
  size_t count = 0;
  while (!feof(stdin)) {
    if (count == capacity) {
      if (capacity >= maximum_material_bytes) {
        free(bytes);
        return 2;
      }
      size_t next = capacity * 2;
      if (next > maximum_material_bytes) {
        next = maximum_material_bytes;
      }
      unsigned char *expanded = realloc(bytes, next);
      if (expanded == NULL) {
        free(bytes);
        return 1;
      }
      bytes = expanded;
      capacity = next;
    }
    count += fread(bytes + count, 1, capacity - count, stdin);
    if (ferror(stdin)) {
      free(bytes);
      return 3;
    }
  }
  *buffer = bytes;
  *length = count;
  return 0;
}

int main(void) {
  unsigned char *material = NULL;
  size_t material_length = 0;
  int input_status = read_material(&material, &material_length);
  if (input_status != 0) {
    fprintf(stderr, "anchor helper input failed: %d\n", input_status);
    return 2;
  }
  unsigned char key[32];
  OSStatus key_status = load_or_create_key(key);
  if (key_status != errSecSuccess) {
    free(material);
    fprintf(stderr, "anchor helper keychain failed: %d\n", (int)key_status);
    return 3;
  }
  unsigned char mac[CC_SHA256_DIGEST_LENGTH];
  CCHmac(
      kCCHmacAlgSHA256, key, sizeof(key), material, material_length, mac);
  free(material);
  for (size_t index = 0; index < sizeof(mac); index++) {
    printf("%02x", mac[index]);
  }
  putchar('\n');
  return 0;
}

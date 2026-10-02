/* Spinel's FFI entry points for Puma's existing Ragel HTTP parser. */
#define PUMA_STANDALONE_PARSER
#include "../ext/puma_http11/http11_parser.h"
#include "../ext/puma_http11/http11_parser.c"

#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *name;
  char *value;
  size_t length;
} puma_spinel_field;

typedef struct {
  puma_parser parser;
  puma_spinel_field *fields;
  size_t count;
  size_t capacity;
  char *buffer;
  size_t buffer_length;
  int failure;
} puma_spinel_parser;

static void add_field(puma_parser *parser, const char *name, const char *value, size_t length)
{
  puma_spinel_parser *owner = (puma_spinel_parser *)parser;
  if (owner->failure) return;
  if (owner->count == owner->capacity) {
    size_t capacity = owner->capacity ? owner->capacity * 2 : 16;
    puma_spinel_field *fields = realloc(owner->fields, capacity * sizeof(*fields));
    if (!fields) { owner->failure = 1; return; }
    owner->fields = fields;
    owner->capacity = capacity;
  }
  char *copy = malloc(length + 1);
  if (!copy) { owner->failure = 1; return; }
  memcpy(copy, value, length);
  copy[length] = '\0';
  owner->fields[owner->count++] = (puma_spinel_field){ name, copy, length };
}

static void http_field(puma_parser *parser, const char *field, size_t field_length,
                       const char *value, size_t value_length)
{
  puma_spinel_parser *owner = (puma_spinel_parser *)parser;
  if (field_length > 256 || value_length > 80 * 1024) { owner->failure = 2; return; }
  while (value_length && (value[value_length - 1] == ' ' || value[value_length - 1] == '\t')) value_length--;
  while (value_length && (*value == ' ' || *value == '\t')) { value++; value_length--; }

  char key[262];
  const char *name = key;
  if ((field_length == 14 && !memcmp(field, "CONTENT_LENGTH", 14)) ||
      (field_length == 12 && !memcmp(field, "CONTENT_TYPE", 12))) {
    memcpy(key, field, field_length);
    key[field_length] = '\0';
  } else {
    memcpy(key, "HTTP_", 5);
    memcpy(key + 5, field, field_length);
    key[field_length + 5] = '\0';
  }
  char *stored_name = malloc(strlen(name) + 1);
  if (!stored_name) { owner->failure = 1; return; }
  strcpy(stored_name, name);
  add_field(parser, stored_name, value, value_length);
  if (owner->failure) free(stored_name);
}

#define ELEMENT_CALLBACK(method, key, limit) \
  static void method(puma_parser *parser, const char *value, size_t length) { \
    if (length > (limit)) { ((puma_spinel_parser *)parser)->failure = 2; return; } \
    add_field(parser, key, value, length); \
  }

ELEMENT_CALLBACK(request_method, "REQUEST_METHOD", 20)
ELEMENT_CALLBACK(request_uri, "REQUEST_URI", 1024 * 12)
ELEMENT_CALLBACK(fragment, "FRAGMENT", 1024)
ELEMENT_CALLBACK(request_path, "REQUEST_PATH", 8192)
ELEMENT_CALLBACK(query_string, "QUERY_STRING", 1024 * 10)
ELEMENT_CALLBACK(server_protocol, "SERVER_PROTOCOL", 128)
ELEMENT_CALLBACK(header_done, "__BODY__", 1024 * (80 + 32))

void *puma_spinel_parser_new(void)
{
  puma_spinel_parser *owner = calloc(1, sizeof(*owner));
  if (!owner) return NULL;
  owner->parser.http_field = http_field;
  owner->parser.request_method = request_method;
  owner->parser.request_uri = request_uri;
  owner->parser.fragment = fragment;
  owner->parser.request_path = request_path;
  owner->parser.query_string = query_string;
  owner->parser.server_protocol = server_protocol;
  owner->parser.header_done = header_done;
  puma_parser_init(&owner->parser);
  return owner;
}

void puma_spinel_parser_reset(void *pointer)
{
  puma_spinel_parser *owner = pointer;
  for (size_t i = 0; i < owner->count; i++) {
    if (!strncmp(owner->fields[i].name, "HTTP_", 5) ||
        !strcmp(owner->fields[i].name, "CONTENT_LENGTH") ||
        !strcmp(owner->fields[i].name, "CONTENT_TYPE")) free((void *)owner->fields[i].name);
    free(owner->fields[i].value);
  }
  owner->count = 0;
  owner->failure = 0;
  free(owner->buffer);
  owner->buffer = NULL;
  owner->buffer_length = 0;
  puma_parser_init(&owner->parser);
}

void puma_spinel_parser_free(void *pointer)
{
  if (!pointer) return;
  puma_spinel_parser *owner = pointer;
  puma_spinel_parser_reset(owner);
  free(owner->fields);
  free(owner);
}

size_t puma_spinel_parser_execute(void *pointer, const char *data, size_t length, size_t offset)
{
  puma_spinel_parser *owner = pointer;
  if (offset >= length) { owner->failure = 3; return owner->parser.nread; }
  /* Ragel mutates header names, so retain the writable copy across reads. */
  char *copy = realloc(owner->buffer, length + 1);
  if (!copy) { owner->failure = 1; return owner->parser.nread; }
  owner->buffer = copy;
  size_t old_length = owner->buffer_length <= length ? owner->buffer_length : 0;
  memcpy(copy + old_length, data + old_length, length - old_length);
  copy[length] = '\0';
  owner->buffer_length = length;
  puma_parser_execute(&owner->parser, copy, length, offset);
  if (owner->parser.nread > 1024 * (80 + 32)) owner->failure = 2;
  return owner->parser.nread;
}

int puma_spinel_parser_error(void *pointer)
{
  puma_spinel_parser *owner = pointer;
  return owner->failure || puma_parser_has_error(&owner->parser);
}

int puma_spinel_parser_finished(void *pointer)
{
  puma_spinel_parser *owner = pointer;
  return !owner->failure && puma_parser_is_finished(&owner->parser);
}

int puma_spinel_parser_finish(void *pointer)
{
  puma_spinel_parser *owner = pointer;
  return !owner->failure && puma_parser_finish(&owner->parser) == 1;
}

size_t puma_spinel_parser_field_count(void *pointer) { return ((puma_spinel_parser *)pointer)->count; }
size_t puma_spinel_parser_nread(void *pointer) { return ((puma_spinel_parser *)pointer)->parser.nread; }
const char *puma_spinel_parser_field_name(void *pointer, size_t index) { return ((puma_spinel_parser *)pointer)->fields[index].name; }
size_t puma_spinel_parser_field_length(void *pointer, size_t index) { return ((puma_spinel_parser *)pointer)->fields[index].length; }
void puma_spinel_parser_field_copy(void *pointer, size_t index, void *destination)
{
  puma_spinel_field *field = &((puma_spinel_parser *)pointer)->fields[index];
  memcpy(destination, field->value, field->length);
}

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* The custom mutators in tests/fuzz call this libFuzzer entry point; the run-once standalone driver
 * never invokes a mutator, so the reproducers only need the symbol to link. */
size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size);
size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size)
{
	(void)data; (void)size; (void)max_size;
	abort();
}

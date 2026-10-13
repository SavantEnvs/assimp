// Fuzzes the C API's log-stream lifecycle (aiGetPredefinedLogStream / aiAttachLogStream /
// aiDetachLogStream) interleaved with imports. Each input byte is one operation; a stream's state
// lives in assimp's globals, so a bug in it shows across operations and across inputs.
#include <assimp/cimport.h>
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    aiLogStream stream = {nullptr, nullptr};
    bool attached = false;

    for (size_t i = 0; i < size; ++i) {
        switch (data[i] & 3) {
        case 0:
            stream = aiGetPredefinedLogStream(aiDefaultLogStream_STDOUT, nullptr);
            attached = false;
            break;
        case 1:
            if (stream.callback != nullptr && !attached) {
                aiAttachLogStream(&stream);
                attached = true;
            }
            break;
        case 2:
            if (attached) {
                aiDetachLogStream(&stream);
                attached = false;
            }
            break;
        default: {
            Assimp::Importer importer;
            importer.ReadFileFromMemory(data + i + 1, size - i - 1,
                aiProcessPreset_TargetRealtime_Quality, nullptr);
            return 0;
        }
        }
    }
    return 0;
}

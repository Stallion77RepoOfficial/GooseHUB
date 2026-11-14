#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3dx9.h>
#include <cstdio>
#include <cstring>

// Run beside a supplied d3dx9_31.dll with "native", or without one with "builtin".
int main(int argc, char **argv) {
  if (argc != 2 || (std::strcmp(argv[1], "native") && std::strcmp(argv[1], "builtin"))) return 1;
  HMODULE library = LoadLibraryW(L"d3dx9_31.dll");
  if (!library) { std::printf("LoadLibrary failed: %lu\n", GetLastError()); return 2; }
  bool builtin = !std::memcmp(reinterpret_cast<const char *>(library) + 0x40, "Wine builtin DLL", 16);
  std::printf("D3DX provider: %s\n", builtin ? "builtin" : "native");
  if (builtin != !std::strcmp(argv[1], "builtin")) return 3;
  auto compile = reinterpret_cast<decltype(&D3DXCompileShader)>(GetProcAddress(library, "D3DXCompileShader"));
  if (!compile) return 4;
  const char shader[] = "float4 main(float2 uv : TEXCOORD0) : COLOR0 { return float4(uv, 0.25, 1.0); }";
  ID3DXBuffer *code = nullptr, *errors = nullptr;
  HRESULT result = compile(shader, sizeof(shader) - 1, nullptr, nullptr, "main", "ps_2_0", 0, &code, &errors, nullptr);
  if (errors) { std::printf("%.*s\n", static_cast<int>(errors->GetBufferSize()), static_cast<const char *>(errors->GetBufferPointer())); errors->Release(); }
  if (FAILED(result) || !code) { std::printf("Compile failed: %08lx\n", static_cast<unsigned long>(result)); return 5; }
  bool valid = code->GetBufferSize() >= 8 && *static_cast<const DWORD *>(code->GetBufferPointer()) == 0xffff0200;
  std::printf("Shader bytes: %lu; pixel shader 2.0: %s\n", code->GetBufferSize(), valid ? "PASS" : "FAIL");
  code->Release(); FreeLibrary(library);
  return valid ? 0 : 6;
}

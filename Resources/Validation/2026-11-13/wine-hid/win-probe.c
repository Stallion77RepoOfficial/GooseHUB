#define UNICODE
#define _UNICODE
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <stdio.h>
#include <wchar.h>

static BOOL CALLBACK child(HWND h, LPARAM unused) {
    wchar_t text[1024], cls[128];
    GetWindowTextW(h, text, 1024); GetClassNameW(h, cls, 128);
    wprintf(L"  CHILD %p ID=%d class=%ls text=%ls\n", h, GetDlgCtrlID(h), cls, text);
    return TRUE;
}
static BOOL CALLBACK window(HWND h, LPARAM unused) {
    wchar_t text[1024], cls[128]; DWORD pid;
    if (!IsWindowVisible(h)) return TRUE;
    GetWindowTextW(h, text, 1024); GetClassNameW(h, cls, 128);
    GetWindowThreadProcessId(h, &pid);
    wprintf(L"WINDOW %p PID=%lu class=%ls text=%ls\n", h, pid, cls, text);
    EnumChildWindows(h, child, 0);
    return TRUE;
}
int wmain(int argc, wchar_t **argv) {
    if (argc > 1 && !wcscmp(argv[1], L"--hold")) { Sleep(60000); return 0; }
    if (argc > 2 && !wcscmp(argv[1], L"--exec")) {
        STARTUPINFOW startup = {sizeof(startup)}; PROCESS_INFORMATION process; DWORD code;
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        if (!CreateProcessW(NULL, argv[2], NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) return 125;
        WaitForSingleObject(process.hProcess, INFINITE); GetExitCodeProcess(process.hProcess, &code);
        CloseHandle(process.hThread); CloseHandle(process.hProcess); return code;
    }
    if (argc > 2 && !wcscmp(argv[1], L"--click")) {
        HWND h = (HWND)(UINT_PTR)wcstoull(argv[2], NULL, 16);
        if (!IsWindow(h)) return 2;
        SendMessageW(h, BM_CLICK, 0, 0); return 0;
    }
    if (argc == 1) { EnumWindows(window, 0); return 0; }
    GUID guid; HidD_GetHidGuid(&guid);
    HDEVINFO info = SetupDiGetClassDevsW(&guid, NULL, NULL, DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);
    SP_DEVICE_INTERFACE_DATA iface = {sizeof(iface)};
    for (DWORD i=0; SetupDiEnumDeviceInterfaces(info, NULL, &guid, i, &iface); ++i) {
        DWORD bytes=0; SetupDiGetDeviceInterfaceDetailW(info, &iface, NULL, 0, &bytes, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_W d = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, bytes);
        d->cbSize=sizeof(*d);
        if (SetupDiGetDeviceInterfaceDetailW(info, &iface, d, bytes, NULL, NULL)) {
            HANDLE h=CreateFileW(d->DevicePath, 0, FILE_SHARE_READ|FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            HIDD_ATTRIBUTES attrs = {sizeof(attrs)}; HIDP_CAPS caps={0}; PHIDP_PREPARSED_DATA data=NULL;
            BOOL valid=HidD_GetAttributes(h, &attrs);
            if (HidD_GetPreparsedData(h, &data)) { HidP_GetCaps(data, &caps); HidD_FreePreparsedData(data); }
            wprintf(L"HID VID=%04x PID=%04x usage=%04x:%04x in=%u out=%u feature=%u open=%d attrs=%d path=%ls\n",
                attrs.VendorID,attrs.ProductID,caps.UsagePage,caps.Usage,caps.InputReportByteLength,caps.OutputReportByteLength,caps.FeatureReportByteLength,h!=INVALID_HANDLE_VALUE,valid,d->DevicePath);
            if (!wcscmp(argv[1], L"--feature") && attrs.VendorID == 0xb6a4 && attrs.ProductID == 0x40c1 && caps.FeatureReportByteLength == 41) {
                BYTE report[41] = {6};
                CloseHandle(h);
                h = CreateFileW(d->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
                SetLastError(0);
                BOOL ok = HidD_GetFeature(h, report, sizeof(report)); DWORD error = GetLastError();
                wprintf(L"FEATURE readWriteOpen=%d readSuccess=%d error=%lu reportID=%u firstBytes=%02x,%02x,%02x,%02x\n", h!=INVALID_HANDLE_VALUE,ok,error,report[0],report[1],report[2],report[3],report[4]);
            }
            if (h!=INVALID_HANDLE_VALUE) CloseHandle(h);
        }
        HeapFree(GetProcessHeap(),0,d);
    }
    wprintf(L"Enum result lastError=%lu\n",GetLastError());
    SetupDiDestroyDeviceInfoList(info); return 0;
}

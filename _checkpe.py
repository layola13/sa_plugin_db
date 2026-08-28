import os, struct
def pe_stack(path):
    with open(path,'rb') as f:
        d=f.read()
    if d[:2]!=b'MZ': return None
    e_lfanew=struct.unpack_from('<I',d,0x3C)[0]
    sig=struct.unpack_from('<H',d,e_lfanew)[0]
    # PE32 optional header: after PE\0\0 + COFF header(20 bytes). OptionalHeader magic at e_lfanew+24
    opt=e_lfanew+24
    magic=struct.unpack_from('<H',d,opt)[0]
    if magic==0x20b: # PE32+
        SizeOfStackReserve=struct.unpack_from('<Q',d,opt+16)[0]
    else:
        SizeOfStackReserve=struct.unpack_from('<I',d,opt+12)[0]
    return SizeOfStackReserve

for root,_,files in os.walk(r"D:\projects\sla\sa_plugin_db\.zig-cache\o"):
    for fn in files:
        if fn.endswith(".out") and "db_erp_indexed" in fn:
            p=os.path.join(root,fn)
            print(fn, "stack=", pe_stack(p))

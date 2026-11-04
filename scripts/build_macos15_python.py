from pathlib import Path
import os,subprocess
root=Path(os.environ.get('DUMPSHOP_RUNTIME_BUILD', str(Path(__file__).resolve().parents[1]/'.build/macos15'))).resolve()
prefix=root/'prefix';dest=root/'python15'
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
env=os.environ.copy();env.update(MACOSX_DEPLOYMENT_TARGET='15.0',SDKROOT=sdk,CC='/usr/bin/clang',CXX='/usr/bin/clang++',PATH='/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',CFLAGS='-O2 -mmacosx-version-min=15.0',CPPFLAGS='-I'+str(prefix/'include'),LDFLAGS='-L'+str(prefix/'lib')+' -Wl,-rpath,'+str(prefix/'lib')+' -mmacosx-version-min=15.0',PKG_CONFIG_PATH='',PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'),ac_cv_header_lzma_h='no')
log=(root/'logs/build-python.log').open('w')
def run(args):subprocess.run(args,cwd=root/'src/python',env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
run(['./configure','--prefix='+str(dest),'--enable-shared','--without-static-libpython','--disable-test-modules','--with-openssl='+str(prefix),'--with-openssl-rpath=auto','--with-ensurepip=install','--without-system-libmpdec'])
run(['make','-j6']);run(['make','install']);print('Built Python 3.13.15 for macOS 15',flush=True)

from pathlib import Path
import concurrent.futures,os,subprocess
root=Path(os.environ.get('DUMPSHOP_RUNTIME_BUILD', str(Path(__file__).resolve().parents[1]/'.build/macos15'))).resolve()
prefix=root/'prefix'
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
env=os.environ.copy()
env.update(MACOSX_DEPLOYMENT_TARGET='15.0',SDKROOT=sdk,CC='/usr/bin/clang',CXX='/usr/bin/clang++',
 PATH=str(prefix/'bin')+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
 CFLAGS='-O2 -mmacosx-version-min=15.0',CXXFLAGS='-O2 -mmacosx-version-min=15.0',
 CPPFLAGS='-I'+str(prefix/'include'),LDFLAGS='-L'+str(prefix/'lib')+' -Wl,-rpath,'+str(prefix/'lib')+' -mmacosx-version-min=15.0',
 PKG_CONFIG_PATH='',PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'),
 libcurl_CFLAGS='-I'+sdk+'/usr/include',libcurl_LIBS='-lcurl')
def run(name,args):
 with (root/'logs'/('build-'+name+'.log')).open('a') as log:
  subprocess.run(args,cwd=root/'src'/name,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
def autotools(name,*args):
 marker=root/'src'/name/'.completed'
 if marker.exists():return
 print('Building '+name,flush=True)
 run(name,['./autogen.sh' if (root/'src'/name/'autogen.sh').exists() else './configure','--prefix='+str(prefix),'--disable-static',*args]);run(name,['make','-j4']);run(name,['make','install'])
 marker.touch();print('Built '+name,flush=True)
def openssl():
 name='openssl@3';marker=root/'src'/name/'.completed'
 if marker.exists():return
 print('Building OpenSSL for macOS 15',flush=True)
 run(name,['/usr/bin/perl','./Configure','darwin64-arm64-cc','--prefix='+str(prefix),'--openssldir='+str(prefix/'etc/ssl'),'shared','no-tests','-mmacosx-version-min=15.0'])
 run(name,['make','-j4']);run(name,['make','install_sw']);marker.touch();print('Built OpenSSL',flush=True)
def libzip():
 name='libzip';marker=root/'src'/name/'.completed'
 if marker.exists():return
 print('Building libzip',flush=True)
 run(name,['cmake','-S','.','-B','build15','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0','-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew','-DCMAKE_PREFIX_PATH='+str(prefix),'-DENABLE_LZMA=OFF','-DENABLE_ZSTD=OFF','-DENABLE_OPENSSL=OFF','-DENABLE_COMMONCRYPTO=ON','-DBUILD_TOOLS=OFF','-DBUILD_REGRESS=OFF','-DBUILD_EXAMPLES=OFF','-DBUILD_DOC=OFF'])
 run(name,['cmake','--build','build15','-j4']);run(name,['cmake','--install','build15']);marker.touch();print('Built libzip',flush=True)
autotools('libplist','--without-cython','--without-tests')
autotools('libimobiledevice-glue')
autotools('libusbmuxd')
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 jobs=[pool.submit(autotools,'libtatsu'),pool.submit(libzip)]
 for job in jobs:job.result()
openssl()
autotools('libimobiledevice','--without-cython','--disable-silent-rules')
autotools('ideviceinstaller')
autotools('sshpass')
print('Native dependency build complete',flush=True)

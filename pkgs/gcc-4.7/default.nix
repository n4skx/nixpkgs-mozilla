{ stdenv, lib, fetchurl, noSysDirs
, langC ? true, langCC ? true, langFortran ? false
, langJava ? false
, langAda ? false
, langVhdl ? false
, langGo ? false
, profiledCompiler ? false
, staticCompiler ? false
, enableShared ? true
, texinfo ? null
, perl ? null # optional, for texi2pod (then pod2man); required for Java
, gmp, mpfr, mpc, gettext, which
, libelf                      # optional, for link-time optimizations (LTO)
, ppl ? null, cloog ? null # optional, for the Graphite optimization framework.
, zlib ? null, boehmgc ? null
, zip ? null, unzip ? null, pkg-config ? null, gtk ? null, libart_lgpl ? null
, libX11 ? null, libXt ? null, libSM ? null, libICE ? null, libXtst ? null
, libXrender ? null, xproto ? null, renderproto ? null, xextproto ? null
, libXrandr ? null, libXi ? null, inputproto ? null, randrproto ? null
, gnatboot ? null
, enableMultilib ? false
, enablePlugin ? true             # whether to support user-supplied plug-ins
, name ? "gcc"
, cross ? null
, binutilsCross ? null
, libcCross ? null
, crossStageStatic ? true
, gnat ? null
, libpthread ? null, libpthreadCross ? null  # required for GNU/Hurd
, stripped ? true
, gnused ? null
}:

assert langJava     -> zip != null && unzip != null
                       && zlib != null && boehmgc != null
                       && perl != null;  # for `--enable-java-home'
assert langAda      -> gnatboot != null;
assert langVhdl     -> gnat != null;

# LTO needs libelf and zlib.
assert libelf != null -> zlib != null;

# Make sure we get GNU sed.
assert stdenv.isDarwin -> gnused != null;

# The go frontend is written in c++
assert langGo -> langCC;

with lib;
with builtins;

let version = "4.7.3";

    # Whether building a cross-compiler for GNU/Hurd.
    crossGNU = cross != null && cross.config == "i586-pc-gnu";

  /* gccinstall.info says that "parallel make is currently not supported since
     collisions in profile collecting may occur".

     Parallel make of gfortran is disabled because of an apparent race
     condition concerning the generation of "bconfig.h". Please try and
     re-enable parallel make for a later release of gfortran to check whether
     the error has been fixed.
  */
    enableParallelBuilding = !profiledCompiler && !langFortran;

    patches = []
      ++ optional enableParallelBuilding ./parallel-bconfig-4.7.patch
      ++ optional stdenv.isArm [ ./arm-eabi.patch ]
      ++ optional (cross != null) ./libstdc++-target.patch
      # ++ optional noSysDirs ./no-sys-dirs.patch
      # The GNAT Makefiles did not pay attention to CFLAGS_FOR_TARGET for its
      # target libraries and tools.
      ++ optional langAda ./gnat-cflags.patch
      ++ optional langFortran ./gfortran-driving.patch;

    javaEcj = fetchurl {
      # The `$(top_srcdir)/ecj.jar' file is automatically picked up at
      # `configure' time.

      # XXX: Eventually we might want to take it from upstream.
      url = "ftp://sourceware.org/pub/java/ecj-4.3.jar";
      sha256 = "0jz7hvc0s6iydmhgh5h2m15yza7p2rlss2vkif30vm9y77m97qcx";
    };

    # Antlr (optional) allows the Java `gjdoc' tool to be built.  We want a
    # binary distribution here to allow the whole chain to be bootstrapped.
    javaAntlr = fetchurl {
      url = "http://www.antlr.org/download/antlr-3.1.3.jar";
      sha256 = "1f41j0y4kjydl71lqlvr73yagrs2jsg1fjymzjz66mjy7al5lh09";
    };

    xorg = [
      libX11 libXt libSM libICE libXtst libXrender libXrandr libXi
      xproto renderproto xextproto inputproto randrproto
    ];

    javaAwtGtk = langJava && gtk != null;

    /* Platform flags */
    platformFlags = let
        gccArch = lib.attrByPath [ "platform" "gcc" "arch" ] null stdenv;
        gccCpu = lib.attrByPath [ "platform" "gcc" "cpu" ] null stdenv;
        gccAbi = lib.attrByPath [ "platform" "gcc" "abi" ] null stdenv;
        gccFpu = lib.attrByPath [ "platform" "gcc" "fpu" ] null stdenv;
        gccFloat = lib.attrByPath [ "platform" "gcc" "float" ] null stdenv;
        gccMode = lib.attrByPath [ "platform" "gcc" "mode" ] null stdenv;
        withArch = if gccArch != null then " --with-arch=${gccArch}" else "";
        withCpu = if gccCpu != null then " --with-cpu=${gccCpu}" else "";
        withAbi = if gccAbi != null then " --with-abi=${gccAbi}" else "";
        withFpu = if gccFpu != null then " --with-fpu=${gccFpu}" else "";
        withFloat = if gccFloat != null then " --with-float=${gccFloat}" else "";
        withMode = if gccMode != null then " --with-mode=${gccMode}" else "";
      in
        (withArch +
        withCpu +
        withAbi +
        withFpu +
        withFloat +
        withMode);

    /* Cross-gcc settings */
    crossMingw = (cross != null && cross.libc == "msvcrt");
    crossConfigureFlags = let
        gccArch = lib.attrByPath [ "gcc" "arch" ] null cross;
        gccCpu = lib.attrByPath [ "gcc" "cpu" ] null cross;
        gccAbi = lib.attrByPath [ "gcc" "abi" ] null cross;
        gccFpu = lib.attrByPath [ "gcc" "fpu" ] null cross;
        gccFloat = lib.attrByPath [ "gcc" "float" ] null cross;
        gccMode = lib.attrByPath [ "gcc" "mode" ] null cross;
        withArch = if gccArch != null then " --with-arch=${gccArch}" else "";
        withCpu = if gccCpu != null then " --with-cpu=${gccCpu}" else "";
        withAbi = if gccAbi != null then " --with-abi=${gccAbi}" else "";
        withFpu = if gccFpu != null then " --with-fpu=${gccFpu}" else "";
        withFloat = if gccFloat != null then " --with-float=${gccFloat}" else "";
        withMode = if gccMode != null then " --with-mode=${gccMode}" else "";
      in
        "--target=${cross.config}" +
        withArch +
        withCpu +
        withAbi +
        withFpu +
        withFloat +
        withMode +
        (if crossMingw && crossStageStatic then
          " --with-headers=${libcCross}/include" +
          " --with-gcc" +
          " --with-gnu-as" +
          " --with-gnu-ld" +
          " --with-gnu-ld" +
          " --disable-shared" +
          " --disable-nls" +
          " --disable-debug" +
          " --enable-sjlj-exceptions" +
          " --enable-threads=win32" +
          " --disable-win32-registry"
          else if crossStageStatic then
          " --disable-libssp --disable-nls" +
          " --without-headers" +
          " --disable-threads " +
          " --disable-libmudflap " +
          " --disable-libgomp " +
          " --disable-libquadmath" +
          " --disable-shared" +
          " --disable-decimal-float" # libdecnumber requires libc
          else
          " --with-headers=${libcCross}/include" +
          " --enable-__cxa_atexit" +
          " --enable-long-long" +
          (if crossMingw then
            " --enable-threads=win32" +
            " --enable-sjlj-exceptions" +
            " --enable-hash-synchronization" +
            " --disable-libssp" +
            " --disable-nls" +
            " --with-dwarf2" +
            # I think noone uses shared gcc libs in mingw, so we better do the same.
            # In any case, mingw32 g++ linking is broken by default with shared libs,
            # unless adding "-lsupc++" to any linking command. I don't know why.
            " --disable-shared" +
            (if cross.config == "x86_64-w64-mingw32" then
              # To keep ABI compatibility with upstream mingw-w64
              " --enable-fully-dynamic-string"
              else "")
            else (if cross.libc == "uclibc" then
              # In uclibc cases, libgomp needs an additional '-ldl'
              # and as I don't know how to pass it, I disable libgomp.
              " --disable-libgomp" else "") +
            " --enable-threads=posix" +
            " --enable-nls" +
            " --disable-decimal-float") # No final libdecnumber (it may work only in 386)
          );
    stageNameAddon = if crossStageStatic then "-stage-static" else
      "-stage-final";
    crossNameAddon = if cross != null then "-${cross.config}" + stageNameAddon else "";

  bootstrap = cross == null && !stdenv.isArm && !stdenv.isMips;

in

# We need all these X libraries when building AWT with GTK+.
assert gtk != null -> (filter (x: x == null) xorg) == [];

stdenv.mkDerivation ({
  name = "${name}${if stripped then "" else "-debug"}-${version}" + crossNameAddon;

  builder = ./builder.sh;

  src = fetchurl {
    url = "mirror://gnu/gcc/gcc-${version}/gcc-${version}.tar.bz2";
    sha256 = "1hx9h64ivarlzi4hxvq42as5m9vlr5cyzaaq4gzj4i619zmkfz1g";
  };

  inherit patches;

  postPatch =
    if (stdenv.isGNU
        || (libcCross != null                  # e.g., building `gcc.crossDrv'
            && libcCross ? crossConfig
            && libcCross.crossConfig == "i586-pc-gnu")
        || (crossGNU && libcCross != null))
    then
      # On GNU/Hurd glibc refers to Hurd & Mach headers and libpthread is not
      # in glibc, so add the right `-I' flags to the default spec string.
      assert libcCross != null -> libpthreadCross != null;
      let
        libc = if libcCross != null then libcCross else stdenv.glibc;
        gnu_h = "gcc/config/gnu.h";
        extraCPPDeps =
             libc.propagatedBuildInputs
          ++ lib.optional (libpthreadCross != null) libpthreadCross
          ++ lib.optional (libpthread != null) libpthread;
        extraCPPSpec =
          concatStrings (intersperse " "
                          (map (x: "-I${x}/include") extraCPPDeps));
        extraLibSpec =
          if libpthreadCross != null
          then "-L${libpthreadCross}/lib ${libpthreadCross.TARGET_LDFLAGS}"
          else "-L${libpthread}/lib";
      in
        '' echo "augmenting \`CPP_SPEC' in \`${gnu_h}' with \`${extraCPPSpec}'..."
           sed -i "${gnu_h}" \
               -es'|CPP_SPEC *"\(.*\)$|CPP_SPEC "${extraCPPSpec} \1|g'

           echo "augmenting \`LIB_SPEC' in \`${gnu_h}' with \`${extraLibSpec}'..."
           sed -i "${gnu_h}" \
               -es'|LIB_SPEC *"\(.*\)$|LIB_SPEC "${extraLibSpec} \1|g'

           echo "setting \`NATIVE_SYSTEM_HEADER_DIR' and \`STANDARD_INCLUDE_DIR' to \`${libc}/include'..."
           sed -i "${gnu_h}" \
               -es'|#define STANDARD_INCLUDE_DIR.*$|#define STANDARD_INCLUDE_DIR "${libc}/include"|g'
        ''
    else if cross != null || stdenv.gcc.libc != null then
      # On NixOS, use the right path to the dynamic linker instead of
      # `/lib/ld*.so'.
      let
        libc = if libcCross != null then libcCross else stdenv.gcc.libc;
      in
        '' echo "fixing the \`GLIBC_DYNAMIC_LINKER' and \`UCLIBC_DYNAMIC_LINKER' macros..."
           for header in "gcc/config/"*-gnu.h "gcc/config/"*"/"*.h
           do
             grep -q LIBC_DYNAMIC_LINKER "$header" || continue
             echo "  fixing \`$header'..."
             sed -i "$header" \
                 -e 's|define[[:blank:]]*\([UCG]\+\)LIBC_DYNAMIC_LINKER\([0-9]*\)[[:blank:]]"\([^\"]\+\)"$|define \1LIBC_DYNAMIC_LINKER\2 "${libc}\3"|g'
           done
        ''
    else null;

  inherit noSysDirs staticCompiler langJava crossStageStatic
    libcCross crossMingw;

  nativeBuildInputs = [ texinfo which gettext ]
    ++ (optional (perl != null) perl)
    ++ (optional javaAwtGtk pkg-config);

  buildInputs = [ gmp mpfr mpc libelf ]
    ++ (optional (ppl != null) ppl)
    ++ (optional (cloog != null) cloog)
    ++ (optional (zlib != null) zlib)
    ++ (optionals langJava [ boehmgc zip unzip ])
    ++ (optionals javaAwtGtk ([ gtk libart_lgpl ] ++ xorg))
    ++ (optionals (cross != null) [binutilsCross])
    ++ (optionals langAda [gnatboot])
    ++ (optionals langVhdl [gnat])

    # The builder relies on GNU sed (for instance, Darwin's `sed' fails with
    # "-i may not be used with stdin"), and `stdenvNative' doesn't provide it.
    ++ (optional stdenv.isDarwin gnused)
    ;

  NIX_LDFLAGS = lib.optionalString  stdenv.isSunOS "-lm -ldl";

  preConfigure = ''
    configureFlagsArray=(
      ${lib.optionalString (ppl != null && ppl ? dontDisableStatic && ppl.dontDisableStatic)
        "'--with-host-libstdcxx=-lstdc++ -lgcc_s'"}
      ${lib.optionalString (ppl != null && stdenv.isSunOS)
        "\"--with-host-libstdcxx=-Wl,-rpath,\$prefix/lib/amd64 -lstdc++\"
         \"--with-boot-ldflags=-L../prev-x86_64-pc-solaris2.11/libstdc++-v3/src/.libs\""}
    );
    ${lib.optionalString (stdenv.isSunOS && stdenv.is64bit)
      ''
        export NIX_LDFLAGS=`echo $NIX_LDFLAGS | sed -e s~$prefix/lib~$prefix/lib/amd64~g`
        export LDFLAGS_FOR_TARGET="-Wl,-rpath,$prefix/lib/amd64 $LDFLAGS_FOR_TARGET"
        export CXXFLAGS_FOR_TARGET="-Wl,-rpath,$prefix/lib/amd64 $CXXFLAGS_FOR_TARGET"
        export CFLAGS_FOR_TARGET="-Wl,-rpath,$prefix/lib/amd64 $CFLAGS_FOR_TARGET"
      ''}
    '';

  # 'iant' at #go-nuts@freenode, gccgo maintainer, said that
  # they have a bug in 4.7.1 if adding "--disable-static"
  dontDisableStatic = langGo || staticCompiler;

  configureFlags = "
    ${if stdenv.isSunOS then
      " --enable-long-long --enable-libssp --enable-threads=posix --disable-nls --enable-__cxa_atexit " +
      # On Illumos/Solaris GNU as is preferred
      " --with-gnu-as --without-gnu-ld "
      else ""}
    --enable-lto
    ${if enableMultilib then "" else "--disable-multilib"}
    ${if enableShared then "" else "--disable-shared"}
    ${if enablePlugin then "--enable-plugin" else "--disable-plugin"}
    ${if ppl != null then "--with-ppl=${ppl} --disable-ppl-version-check" else ""}
    ${if cloog != null then
      "--with-cloog=${cloog} --disable-cloog-version-check --enable-cloog-backend=isl"
      else ""}
    ${if langJava then
      "--with-ecj-jar=${javaEcj} " +

      # Follow Sun's layout for the convenience of IcedTea/OpenJDK.  See
      # <http://mail.openjdk.java.net/pipermail/distro-pkg-dev/2010-April/008888.html>.
      "--enable-java-home --with-java-home=\${prefix}/lib/jvm/jre "
      else ""}
    ${if javaAwtGtk then "--enable-java-awt=gtk" else ""}
    ${if langJava && javaAntlr != null then "--with-antlr-jar=${javaAntlr}" else ""}
    --with-gmp=${gmp}
    --with-mpfr=${mpfr}
    --with-mpc=${mpc}
    ${if libelf != null then "--with-libelf=${libelf}" else ""}
    --disable-libstdcxx-pch
    --without-included-gettext
    --with-system-zlib
    --enable-languages=${
      concatStrings (intersperse ","
        (  optional langC        "c"
        ++ optional langCC       "c++"
        ++ optional langFortran  "fortran"
        ++ optional langJava     "java"
        ++ optional langAda      "ada"
        ++ optional langVhdl     "vhdl"
        ++ optional langGo       "go"
        )
      )
    }
    ${if (stdenv ? glibc && cross == null)
      then " --with-native-system-header-dir=${stdenv.glibc}/include"
      else ""}
    ${if langAda then " --enable-libada" else ""}
    ${if cross == null && stdenv.isi686 then "--with-arch=i686" else ""}
    ${if cross != null then crossConfigureFlags else ""}
    ${if !bootstrap then "--disable-bootstrap" else ""}
    ${if cross == null then platformFlags else ""}
  ";

  targetConfig = if cross != null then cross.config else null;

  buildFlags = if bootstrap then
    (if profiledCompiler then "profiledbootstrap" else "bootstrap")
    else "";

  installTargets =
    if stripped
    then "install-strip"
    else "install";

  crossAttrs = let
    xgccArch = lib.attrByPath [ "gcc" "arch" ] null stdenv.cross;
    xgccCpu = lib.attrByPath [ "gcc" "cpu" ] null stdenv.cross;
    xgccAbi = lib.attrByPath [ "gcc" "abi" ] null stdenv.cross;
    xgccFpu = lib.attrByPath [ "gcc" "fpu" ] null stdenv.cross;
    xgccFloat = lib.attrByPath [ "gcc" "float" ] null stdenv.cross;
    xwithArch = if xgccArch != null then " --with-arch=${xgccArch}" else "";
    xwithCpu = if xgccCpu != null then " --with-cpu=${xgccCpu}" else "";
    xwithAbi = if xgccAbi != null then " --with-abi=${xgccAbi}" else "";
    xwithFpu = if xgccFpu != null then " --with-fpu=${xgccFpu}" else "";
    xwithFloat = if xgccFloat != null then " --with-float=${xgccFloat}" else "";
  in {
    AR = "${stdenv.cross.config}-ar";
    LD = "${stdenv.cross.config}-ld";
    CC = "${stdenv.cross.config}-gcc";
    CXX = "${stdenv.cross.config}-gcc";
    AR_FOR_TARGET = "${stdenv.cross.config}-ar";
    LD_FOR_TARGET = "${stdenv.cross.config}-ld";
    CC_FOR_TARGET = "${stdenv.cross.config}-gcc";
    NM_FOR_TARGET = "${stdenv.cross.config}-nm";
    CXX_FOR_TARGET = "${stdenv.cross.config}-g++";
    # If we are making a cross compiler, cross != null
    NIX_GCC_CROSS = if cross == null then "${stdenv.gccCross}" else "";
    dontStrip = true;
    configureFlags = ''
      ${if enableMultilib then "" else "--disable-multilib"}
      ${if enableShared then "" else "--disable-shared"}
      ${if ppl != null then "--with-ppl=${ppl.crossDrv}" else ""}
      ${if cloog != null then "--with-cloog=${cloog.crossDrv} --enable-cloog-backend=isl" else ""}
      ${if langJava then "--with-ecj-jar=${javaEcj.crossDrv}" else ""}
      ${if javaAwtGtk then "--enable-java-awt=gtk" else ""}
      ${if langJava && javaAntlr != null then "--with-antlr-jar=${javaAntlr.crossDrv}" else ""}
      --with-gmp=${gmp.crossDrv}
      --with-mpfr=${mpfr.crossDrv}
      --disable-libstdcxx-pch
      --without-included-gettext
      --with-system-zlib
      --enable-languages=${
        concatStrings (intersperse ","
          (  optional langC        "c"
          ++ optional langCC       "c++"
          ++ optional langFortran  "fortran"
          ++ optional langJava     "java"
          ++ optional langAda      "ada"
          ++ optional langVhdl     "vhdl"
          ++ optional langGo       "go"
          )
        )
      }
      ${if langAda then " --enable-libada" else ""}
      --target=${stdenv.cross.config}
      ${xwithArch}
      ${xwithCpu}
      ${xwithAbi}
      ${xwithFpu}
      ${xwithFloat}
    '';
    buildFlags = "";
  };


  # Needed for the cross compilation to work
  AR = "ar";
  LD = "ld";
  # http://gcc.gnu.org/install/specific.html#x86-64-x-solaris210
  CC = if stdenv.system == "x86_64-solaris" then "gcc -m64"
       else "gcc";

  # Setting $CPATH and $LIBRARY_PATH to make sure both `gcc' and `xgcc' find
  # the library headers and binaries, regarless of the language being
  # compiled.

  # Note: When building the Java AWT GTK+ peer, the build system doesn't
  # honor `--with-gmp' et al., e.g., when building
  # `libjava/classpath/native/jni/java-math/gnu_java_math_GMP.c', so we just
  # add them to $CPATH and $LIBRARY_PATH in this case.
  #
  # Likewise, the LTO code doesn't find zlib.

  CPATH = concatStrings
            (intersperse ":" (map (x: x + "/include")
                                  (optionals (zlib != null) [ zlib ]
                                   ++ optionals langJava [ boehmgc ]
                                   ++ optionals javaAwtGtk xorg
                                   ++ optionals javaAwtGtk [ gmp mpfr ]
                                   ++ optional (libpthread != null) libpthread
                                   ++ optional (libpthreadCross != null) libpthreadCross

                                   # On GNU/Hurd glibc refers to Mach & Hurd
                                   # headers.
                                   ++ optionals (libcCross != null &&
                                                 hasAttr "propagatedBuildInputs" libcCross)
                                        libcCross.propagatedBuildInputs)));

  LIBRARY_PATH = concatStrings
                   (intersperse ":" (map (x: x + "/lib")
                                         (optionals (zlib != null) [ zlib ]
                                          ++ optionals langJava [ boehmgc ]
                                          ++ optionals javaAwtGtk xlibs
                                          ++ optionals javaAwtGtk [ gmp mpfr ]
                                          ++ optional (libpthread != null) libpthread)));

  EXTRA_TARGET_CFLAGS =
    if cross != null && libcCross != null
    then "-idirafter ${libcCross}/include"
    else null;

  EXTRA_TARGET_LDFLAGS =
    if cross != null && libcCross != null
    then "-B${libcCross}/lib -Wl,-L${libcCross}/lib" +
         (optionalString (libpthreadCross != null)
           " -L${libpthreadCross}/lib -Wl,${libpthreadCross.TARGET_LDFLAGS}")
    else null;

  passthru = { inherit langC langCC langAda langFortran langVhdl
      langGo enableMultilib version; };

  inherit enableParallelBuilding;

  meta = {
    homepage = "http://gcc.gnu.org/";
    license = "GPLv3+";  # runtime support libraries are typically LGPLv3+
    description = "GNU Compiler Collection, version ${version}"
      + (if stripped then "" else " (with debugging info)");

    longDescription = ''
      The GNU Compiler Collection includes compiler front ends for C, C++,
      Objective-C, Fortran, OpenMP for C/C++/Fortran, Java, and Ada, as well
      as libraries for these languages (libstdc++, libgcj, libgomp,...).

      GCC development is a part of the GNU Project, aiming to improve the
      compiler used in the GNU system including the GNU/Linux variant.
    '';

    maintainers = [
      lib.maintainers.ludo
      lib.maintainers.viric
      lib.maintainers.shlevy
    ];

    # Volunteers needed for the {Cyg,Dar}win ports of *PPL.
    # gnatboot is not available out of linux platforms, so we disable the darwin build
    # for the gnat (ada compiler).
    platforms = lib.platforms.linux ++ optionals (langAda == false && libelf == null) [ "i686-darwin" ];
  };
}

// optionalAttrs (cross != null && cross.libc == "msvcrt" && crossStageStatic) {
  makeFlags = [ "all-gcc" "all-target-libgcc" ];
  installTargets = "install-gcc install-target-libgcc";
}


# Strip kills static libs of other archs (hence cross != null)
// optionalAttrs (!stripped || cross != null) { dontStrip = true; NIX_STRIP_DEBUG = 0; }
)

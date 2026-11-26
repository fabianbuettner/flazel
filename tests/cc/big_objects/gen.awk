# Writes main over n template instantiations, a COMDAT section each unless
# internal puts them in an anonymous namespace: volatile variables, or with
# functions, functions that throw, so each has unwind data on 64-bit Windows.
BEGIN {
    print "#include \"big_objects/report.h\""
    if (internal) print "namespace {"
    if (functions) print "template <int N> int f(bool fail) { if (fail) throw N; return N % 7; }"
    else print "template <int N> volatile int value = N % 7;"
    if (internal) print "}"
    if (functions) print "using Entry = int (*)(bool);"
    else print "using Entry = volatile int*;"
    print "extern Entry const entries[];"
    print "Entry const entries[] = {"
    sum = 0
    for (i = 0; i < n; i++) {
        if (functions) printf "    &f<%d>,\n", i
        else printf "    &value<%d>,\n", i
        sum += i % 7
    }
    print "};"
    print "int main() {"
    print "    long sum = 0, caught = 0;"
    print "    for (Entry e : entries) {"
    if (functions) {
        print "        sum += e(false);"
        print "        try {"
        print "            e(true);"
        print "        } catch (int thrown) {"
        print "            caught += thrown % 7;"
        print "        }"
    } else {
        print "        sum += *e;"
    }
    print "    }"
    printf "    return report(sum == %d && caught == %d ? nullptr : \"wrong sum\");\n", sum, functions ? sum : 0
    print "}"
}

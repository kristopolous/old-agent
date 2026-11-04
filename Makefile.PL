use strict;
use warnings;

# OldAgent has no build step and no dependencies. This exists so
#   perl Makefile.PL && make test && make install
# works on any perl from 5.006 onwards, which is the whole point.

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'OldAgent',
    VERSION_FROM => 'lib/OldAgent.pm',
    ABSTRACT     => 'A tiny text-only agent for old perl and older machines',
    AUTHOR       => 'oldagent contributors',
    LICENSE      => 'perl',
    EXE_FILES    => ['oa'],
    PREREQ_PM    => {},          # deliberately empty, keep it that way
    test         => { TESTS      => 't/*.t' },
    dist         => { COMPRESS   => 'gzip -9f', SUFFIX => 'gz' },
    clean        => { FILES      => 'oldagent-* Makefile.old *.bak' },
);

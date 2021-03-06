####################################################################################################################################
# Archive Push Tests
####################################################################################################################################
package pgBackRestTest::Module::Archive::ArchivePushPerlTest;
use parent 'pgBackRestTest::Env::HostEnvTest';

####################################################################################################################################
# Perl includes
####################################################################################################################################
use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);
use English '-no_match_vars';

use File::Basename qw(dirname);
use Storable qw(dclone);

use pgBackRest::Archive::Common;
use pgBackRest::Archive::Push::Push;
use pgBackRest::Archive::Push::Async;
use pgBackRest::Archive::Push::File;
use pgBackRest::Common::Exception;
use pgBackRest::Common::Lock;
use pgBackRest::Common::Log;
use pgBackRest::Common::Wait;
use pgBackRest::Config::Config;
use pgBackRest::DbVersion;
use pgBackRest::Protocol::Helper;
use pgBackRest::Protocol::Storage::Helper;
use pgBackRest::Storage::Helper;

use pgBackRestTest::Env::HostEnvTest;
use pgBackRestTest::Common::ExecuteTest;
use pgBackRestTest::Env::Host::HostBackupTest;
use pgBackRestTest::Common::RunTest;

####################################################################################################################################
# initModule
####################################################################################################################################
sub initModule
{
    my $self = shift;

    $self->{strDbPath} = $self->testPath() . '/db';
    $self->{strWalPath} = "$self->{strDbPath}/pg_xlog";
    $self->{strWalStatusPath} = "$self->{strWalPath}/archive_status";
    $self->{strWalHash} = $self->walGenerateContentChecksum(PG_VERSION_94);
    $self->{strRepoPath} = $self->testPath() . '/repo';
    $self->{strArchivePath} = "$self->{strRepoPath}/archive/" . $self->stanza();
    $self->{strSpoolPath} = "$self->{strArchivePath}/out";
}

####################################################################################################################################
# initTest
####################################################################################################################################
sub initTest
{
    my $self = shift;

    # Create WAL path
    storageTest()->pathCreate($self->{strWalStatusPath}, {bIgnoreExists => true, bCreateParent => true});

    # Create archive info
    storageTest()->pathCreate($self->{strArchivePath}, {bIgnoreExists => true, bCreateParent => true});

    $self->initOption();
    $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

    my $oArchiveInfo = new pgBackRest::Archive::Info($self->{strArchivePath}, false, {bIgnoreMissing => true});
    $oArchiveInfo->create(PG_VERSION_94, $self->dbSysId(PG_VERSION_94), true);

    $self->{strArchiveId} = $oArchiveInfo->archiveId();
}

####################################################################################################################################
# initOption
####################################################################################################################################
sub initOption
{
    my $self = shift;

    $self->optionTestSet(CFGOPT_STANZA, $self->stanza());
    $self->optionTestSet(CFGOPT_PG_PATH, $self->{strDbPath});
    $self->optionTestSet(CFGOPT_REPO_PATH, $self->{strRepoPath});
    $self->optionTestSet(CFGOPT_LOG_PATH, $self->testPath());
    $self->optionTestSetBool(CFGOPT_COMPRESS, false);

    $self->optionTestSet(CFGOPT_DB_TIMEOUT, 5);
    $self->optionTestSet(CFGOPT_PROTOCOL_TIMEOUT, 6);
    $self->optionTestSet(CFGOPT_ARCHIVE_TIMEOUT, 5);
}

####################################################################################################################################
# run
####################################################################################################################################
sub run
{
    my $self = shift;

    ################################################################################################################################
    if ($self->begin("ArchivePushFile::archivePushCheck"))
    {
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        #---------------------------------------------------------------------------------------------------------------------------
        my $strWalSegment = '000000010000000100000001';

        $self->testResult(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strWalSegment}")},
            '(9.4-1, [undef], [undef], [undef])', "${strWalSegment} WAL not found");

        #---------------------------------------------------------------------------------------------------------------------------
        my $strWalMajorPath = "$self->{strArchivePath}/9.4-1/" . substr($strWalSegment, 0, 16);
        my $strWalSegmentHash = "${strWalSegment}-$self->{strWalHash}";

        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strWalSegment);

        storageTest()->pathCreate($strWalMajorPath, {bCreateParent => true});
        storageTest()->put("${strWalMajorPath}/${strWalSegmentHash}");

        $self->testResult(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strWalSegment}")},
            "(9.4-1, $self->{strWalHash}, [undef]," .
                " WAL segment ${strWalSegment} already exists in the archive with the same checksum\n" .
                'HINT: this is valid in some recovery scenarios but may also indicate a problem.)',
            "${strWalSegment} WAL found");

        storageTest()->remove("${strWalMajorPath}/${strWalSegmentHash}");

        #---------------------------------------------------------------------------------------------------------------------------
        $strWalSegmentHash = "${strWalSegment}-10be15a0ab8e1653dfab18c83180e74f1507cab1";

        storageTest()->put("${strWalMajorPath}/${strWalSegmentHash}");

        $self->testException(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strWalSegment}")},
            ERROR_ARCHIVE_DUPLICATE, "WAL segment ${strWalSegment} already exists in the archive");

        #---------------------------------------------------------------------------------------------------------------------------
        $strWalSegment = "${strWalSegment}.partial";
        $strWalSegmentHash = "${strWalSegment}-$self->{strWalHash}";

        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strWalSegment);

        storageTest()->put("${strWalMajorPath}/${strWalSegmentHash}");

        $self->testResult(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strWalSegment}")},
            "(9.4-1, $self->{strWalHash}, [undef]," .
                " WAL segment ${strWalSegment} already exists in the archive with the same checksum\n" .
                'HINT: this is valid in some recovery scenarios but may also indicate a problem.)',
            "${strWalSegment} WAL found");

        storageTest()->remove("${strWalMajorPath}/${strWalSegmentHash}");

        #---------------------------------------------------------------------------------------------------------------------------
        $strWalSegmentHash = "${strWalSegment}-10be15a0ab8e1653dfab18c83180e74f1507cab1";

        storageTest()->put("${strWalMajorPath}/${strWalSegmentHash}");

        $self->testException(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strWalSegment}")},
            ERROR_ARCHIVE_DUPLICATE, "WAL segment ${strWalSegment} already exists in the archive");

        #---------------------------------------------------------------------------------------------------------------------------
        $self->testException(sub {archivePushCheck(
            $strWalSegment, PG_VERSION_94, $self->dbSysId(PG_VERSION_94))},
            ERROR_ASSERT, "xFileExp is required in Storage::Local->hashSize");

        #---------------------------------------------------------------------------------------------------------------------------
        my $strHistoryFile = "00000001.history";

        storageTest()->put("$self->{strArchivePath}/9.4-1/${strHistoryFile}");

        $self->testResult(sub {archivePushCheck(
            $strHistoryFile, PG_VERSION_94, $self->dbSysId(PG_VERSION_94), "$self->{strWalPath}/${strHistoryFile}")},
            '(9.4-1, [undef], [undef], [undef])', "history file ${strHistoryFile} found");
    }

    ################################################################################################################################
    if ($self->begin("ArchivePushFile::archivePushFile"))
    {
        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        $self->optionTestSet(CFGOPT_REPO_HOST, 'localhost');
        $self->optionTestSet(CFGOPT_REPO_HOST_USER, $self->pgUser());
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        protocolGet(CFGOPTVAL_REMOTE_TYPE_BACKUP, undef, {strBackRestBin => $self->backrestExe()});

        # Generate a normal segment
        my $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        $self->testResult(
            sub {archivePushFile($self->{strWalPath}, $strSegment, false, false)}, '[undef]',
            "${strSegment} WAL segment to remote");

        $self->testResult(
            sub {archivePushFile($self->{strWalPath}, $strSegment, false, false)},
            "WAL segment 000000010000000100000001 already exists in the archive with the same checksum\n" .
                'HINT: this is valid in some recovery scenarios but may also indicate a problem.',
            "${strSegment} WAL duplicate segment to remote");

        # Destroy protocol object
        protocolDestroy();

        $self->optionTestClear(CFGOPT_REPO_HOST);
        $self->optionTestClear(CFGOPT_REPO_HOST_USER);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);
    }

    ################################################################################################################################
    if ($self->begin("ArchivePush->readyList()"))
    {
        my $oPushAsync = new pgBackRest::Archive::Push::Async($self->{strWalPath}, $self->{strSpoolPath});
        $self->optionTestSetBool(CFGOPT_ARCHIVE_ASYNC, true);
        $self->optionTestSet(CFGOPT_SPOOL_PATH, $self->{strRepoPath});
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);
        $oPushAsync->initServer();

        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        #---------------------------------------------------------------------------------------------------------------------------
        storageTest()->put("$self->{strWalStatusPath}/" . $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++) . '.done');

        $self->testResult(
            sub {$oPushAsync->readyList()}, '()',
            'ignore files without .ready extension');

        #---------------------------------------------------------------------------------------------------------------------------
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++));
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++));

        $self->testResult(
            sub {$oPushAsync->readyList()}, '(000000010000000100000002, 000000010000000100000003)',
            '.ready files are found');

        storageTest()->put("$self->{strSpoolPath}/000000010000000100000002.ok");
        storageTest()->put("$self->{strSpoolPath}/000000010000000100000003.ok");

        #---------------------------------------------------------------------------------------------------------------------------
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++));

        $self->testResult(
            sub {$oPushAsync->readyList()}, '(000000010000000100000004)',
            'new .ready files are found and duplicates ignored');

        storageTest()->put("$self->{strSpoolPath}/000000010000000100000004.ok");

        #---------------------------------------------------------------------------------------------------------------------------
        $self->testResult(
            sub {$oPushAsync->readyList()}, '()',
            'no new .ready files returns empty list');

        #---------------------------------------------------------------------------------------------------------------------------
        $iWalTimeline++;
        $iWalMinor = 1;

        storageTest()->put("$self->{strWalStatusPath}/00000002.history.ready");

        $self->testResult(
            sub {$oPushAsync->readyList()}, '(00000002.history)',
            'history .ready file');

        storageTest()->put("$self->{strSpoolPath}/00000002.history.ok");

        #---------------------------------------------------------------------------------------------------------------------------
        storageTest()->put(
            "$self->{strWalStatusPath}/" . $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++) . '.00000028.backup.ready');

        $self->testResult(
            sub {$oPushAsync->readyList()}, '(000000020000000100000001.00000028.backup)',
            'backup .ready file');

        storageTest()->put("$self->{strSpoolPath}/000000020000000100000001.00000028.backup.ok");

        #---------------------------------------------------------------------------------------------------------------------------
        storageTest()->remove("$self->{strWalStatusPath}/00000002.history.ready");

        $self->testResult(
            sub {$oPushAsync->readyList()}, '()', 'remove 00000002.history.ok file');

        $self->testResult(
            sub {storageTest()->exists("$self->{strWalStatusPath}/00000002.history.ready")}, false,
            '00000002.history.ok is removed');
    }

    ################################################################################################################################
    if ($self->begin("ArchivePush->dropList()"))
    {
        my $oPushAsync = new pgBackRest::Archive::Push::Async($self->{strWalPath}, $self->{strSpoolPath});
        $self->optionTestSet(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX, PG_WAL_SIZE * 4);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        #---------------------------------------------------------------------------------------------------------------------------
        storageTest()->put("$self->{strWalStatusPath}/" . $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++) . '.ready');
        storageTest()->put("$self->{strWalStatusPath}/" . $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++) . '.ready');
        storageTest()->put("$self->{strWalStatusPath}/" . $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++) . '.ready');

        $self->testResult(
            sub {$oPushAsync->dropList($oPushAsync->readyList())}, '()',
            'WAL files not dropped');

        #---------------------------------------------------------------------------------------------------------------------------
        $self->optionTestSet(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX, PG_WAL_SIZE * 2);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $self->testResult(
            sub {$oPushAsync->dropList($oPushAsync->readyList())},
            '(000000010000000100000001, 000000010000000100000002, 000000010000000100000003)', 'WAL files that exceed queue max');

        # Reset queue max
        $self->optionTestClear(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);
    }

    ################################################################################################################################
    if ($self->begin("ArchivePushAsync->process()"))
    {
        my $oPushAsync = new pgBackRest::Archive::Push::Async(
            $self->{strWalPath}, $self->{strSpoolPath}, $self->backrestExe());

        $self->optionTestSetBool(CFGOPT_ARCHIVE_ASYNC, true);
        $self->optionTestSet(CFGOPT_SPOOL_PATH, $self->{strRepoPath});
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $oPushAsync->initServer();

        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        #---------------------------------------------------------------------------------------------------------------------------
        # Generate a normal segment
        my $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        # Generate an error (.ready file withough a corresponding WAL file)
        my $strSegmentError = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        storageTest()->put("$self->{strWalStatusPath}/$strSegmentError.ready");

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(2, 0, 1, 1)', "process ${strSegment}, ${strSegmentError}");

        $self->testResult(
            sub {storageSpool->list($self->{strSpoolPath})}, "(${strSegment}.ok, ${strSegmentError}.error)",
            "${strSegment} pushed, ${strSegmentError} errored");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, "${strSegment}-$self->{strWalHash}",
            "${strSegment} WAL in archive");

        $self->testResult(
            sub {${storageSpool()->get("$self->{strSpoolPath}/$strSegmentError.error")}},
            ERROR_FILE_OPEN . "\nraised from local-1 process: unable to open $self->{strWalPath}/${strSegmentError}",
            "test ${strSegmentError}.error contents");

        # Remove pushed WAL file
        $self->walRemove($self->{strWalPath}, $strSegment);

        #---------------------------------------------------------------------------------------------------------------------------
        # Fix errored WAL file by providing a valid segment
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegmentError);

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(1, 0, 1, 0)', "process ${strSegment}, ${strSegmentError}");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegmentError)}, "${strSegmentError}-$self->{strWalHash}",
            "${strSegmentError} WAL in archive");

        $self->testResult(sub {storageSpool()->list($self->{strSpoolPath})}, "${strSegmentError}.ok", "${strSegmentError} pushed");

        #---------------------------------------------------------------------------------------------------------------------------
        # Remove previously errored WAL file
        $self->walRemove($self->{strWalPath}, $strSegmentError);

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(0, 0, 0, 0)', "remove ${strSegmentError}.ready");

        $self->testResult(sub {storageSpool()->list($self->{strSpoolPath})}, "[undef]", "${strSegmentError} removed");

        #---------------------------------------------------------------------------------------------------------------------------
        # Enable compression
        $self->optionTestSetBool(CFGOPT_COMPRESS, true);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        # Create history file
        my $strHistoryFile = "00000001.history";

        storageTest()->put("$self->{strWalPath}/${strHistoryFile}");
        storageTest()->put("$self->{strWalStatusPath}/$strHistoryFile.ready");

        # Create backup file
        my $strBackupFile = "${strSegment}.00000028.backup";

        storageTest()->put("$self->{strWalPath}/${strBackupFile}");
        storageTest()->put("$self->{strWalStatusPath}/$strBackupFile.ready");

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(2, 0, 2, 0)', "end processing ${strHistoryFile}, ${strBackupFile}");

        $self->testResult(
            sub {storageSpool()->list($self->{strSpoolPath})}, "(${strHistoryFile}.ok, ${strBackupFile}.ok)",
            "${strHistoryFile}, ${strBackupFile} pushed");

        $self->testResult(
            sub {storageRepo()->exists(STORAGE_REPO_ARCHIVE . "/$self->{strArchiveId}/${strHistoryFile}")}, true,
            "${strHistoryFile} in archive");

        $self->testResult(
            sub {storageRepo()->exists(STORAGE_REPO_ARCHIVE . "/$self->{strArchiveId}/${strBackupFile}")}, true,
            "${strBackupFile} in archive");

        # Remove history and backup files
        storageTest()->remove("$self->{strWalPath}/${strHistoryFile}");
        storageTest()->remove("$self->{strWalStatusPath}/$strHistoryFile.ready");
        storageTest()->remove("$self->{strWalPath}/${strBackupFile}");
        storageTest()->remove("$self->{strWalStatusPath}/$strBackupFile.ready");

        #---------------------------------------------------------------------------------------------------------------------------
        # Generate a normal segment
        $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(1, 0, 1, 0)', "processing ${strSegment}.gz");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, "${strSegment}-$self->{strWalHash}.gz",
            "${strSegment} WAL in archive");

        # Remove the WAL and process so the .ok file is removed
        $self->walRemove($self->{strWalPath}, $strSegment);

        $self->testResult(sub {$oPushAsync->processQueue()}, '(0, 0, 0, 0)', "remove ${strSegment}.ready");

        $self->testResult(sub {storageSpool()->list($self->{strSpoolPath})}, "[undef]", "${strSegment}.ok removed");

        # Generate the same WAL again
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(1, 0, 1, 0)', "processed duplicate ${strSegment}.gz");

        $self->testResult(sub {storageSpool()->list($self->{strSpoolPath})}, "${strSegment}.ok", "${strSegment} pushed");

        $self->testResult(
            sub {${storageSpool()->get("$self->{strSpoolPath}/${strSegment}.ok")}},
            "0\nWAL segment ${strSegment} already exists in the archive with the same checksum\n" .
                'HINT: this is valid in some recovery scenarios but may also indicate a problem.',
            "${strSegment}.ok warning status");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, "${strSegment}-$self->{strWalHash}.gz",
            "${strSegment} WAL in archive");

        # Remove the WAL
        $self->walRemove($self->{strWalPath}, $strSegment);

        # Disable compression
        $self->optionTestSetBool(CFGOPT_COMPRESS, false);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        #---------------------------------------------------------------------------------------------------------------------------
        $self->optionTestSet(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX, PG_WAL_SIZE * 2);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        # Generate WAL to test queue limits
        my @strySegment =
        (
            $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++),
            $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++),
            $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++)
        );

        foreach my $strSegment (@strySegment)
        {
            $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);
        }

        # Process and check results
        $self->testResult(sub {$oPushAsync->processQueue()}, '(3, 3, 1, 0)', "process and drop files");

        $self->testResult(
            sub {storageSpool()->list($self->{strSpoolPath})}, '(' . join('.ok, ', @strySegment) . '.ok)',
            join(', ', @strySegment) . " ok drop files written");

        foreach my $strSegment (@strySegment)
        {
            $self->testResult(
                sub {${storageSpool()->get("$self->{strSpoolPath}/${strSegment}.ok")}},
                $strSegment eq $strySegment[0] ? undef :
                    "0\ndropped WAL file ${strSegment} because archive queue exceeded " . cfgOption(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX) .
                        ' bytes',
                "verify ${strSegment} status");

            $self->walRemove($self->{strWalPath}, $strSegment);
        }

        $self->optionTestClear(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        #---------------------------------------------------------------------------------------------------------------------------
        $self->testResult(sub {$oPushAsync->processQueue()}, '(0, 0, 0, 0)', "final process to remove ok files");

        $self->testResult(sub {storageSpool()->list($self->{strSpoolPath})}, "[undef]", "ok files removed");
    }

    ################################################################################################################################
    if ($self->begin("ArchivePush->process()"))
    {
        my $oPush = new pgBackRest::Archive::Push::Push($self->backrestExe());

        $self->optionTestClear(CFGOPT_ARCHIVE_ASYNC);
        $self->optionTestClear(CFGOPT_SPOOL_PATH);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        my $iProcessId = $PID;

        #---------------------------------------------------------------------------------------------------------------------------
        # Set pg-host to trick archive-push into thinking it is running on the backup server
        $self->optionTestSet(CFGOPT_PG_HOST, BOGUS);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $self->testException(sub {$oPush->process(undef)}, ERROR_HOST_INVALID, 'archive-push operation must run on db host');

        #---------------------------------------------------------------------------------------------------------------------------
        # Reset pg-host
        $self->optionTestClear(CFGOPT_PG_HOST);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $self->testException(sub {$oPush->process(undef)}, ERROR_PARAM_REQUIRED, 'WAL file to push required');

        #---------------------------------------------------------------------------------------------------------------------------
        my $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        $self->testResult(sub {$oPush->process("pg_xlog/${strSegment}")}, undef, "${strSegment} WAL pushed (with relative path)");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, "${strSegment}-$self->{strWalHash}",
            "${strSegment} WAL in archive");

        $self->walRemove($self->{strWalPath}, $strSegment);

        #---------------------------------------------------------------------------------------------------------------------------
        # Set unrealistic queue max to make synchronous push drop a WAL
        $self->optionTestSet(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX, 0);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        $self->testResult(sub {$oPush->process("$self->{strWalPath}/${strSegment}")}, undef, "${strSegment} WAL dropped");
        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, '[undef]',
            "${strSegment} WAL in archive");

        # Set more realistic queue max and allow segment to push
        $self->optionTestSet(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX, PG_WAL_SIZE * 4);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $self->testResult(sub {$oPush->process("$self->{strWalPath}/${strSegment}")}, undef, "${strSegment} WAL pushed");
        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment)}, "${strSegment}-$self->{strWalHash}",
            "${strSegment} WAL in archive");

        $self->walRemove($self->{strWalPath}, $strSegment);

        # Reset queue max
        $self->optionTestClear(CFGOPT_ARCHIVE_PUSH_QUEUE_MAX);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        #---------------------------------------------------------------------------------------------------------------------------
        # Enable async archiving
        $self->optionTestSetBool(CFGOPT_ARCHIVE_ASYNC, true);
        $self->optionTestSet(CFGOPT_SPOOL_PATH, $self->{strRepoPath});
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);
        $self->testResult(sub {$oPush->process("$self->{strWalPath}/${strSegment}")}, undef, "${strSegment} WAL pushed async");

        $self->testResult(
            sub {walSegmentFind(storageRepo(), $self->{strArchiveId}, $strSegment, 5)}, "${strSegment}-$self->{strWalHash}",
            "${strSegment} WAL in archive");

        $self->walRemove($self->{strWalPath}, $strSegment);

        #---------------------------------------------------------------------------------------------------------------------------
        $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        $self->optionTestSet(CFGOPT_REPO_HOST, BOGUS);
        $self->optionTestSet(CFGOPT_PROTOCOL_TIMEOUT, 60);
        $self->optionTestSet(CFGOPT_ARCHIVE_TIMEOUT, 5);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        $self->testResult(sub {$oPush->process("$self->{strWalPath}/${strSegment}")}, undef, 'process connect error');

        # Check contents of error file
        my $strErrorFile = STORAGE_SPOOL_ARCHIVE_OUT . "/${strSegment}.error";
        my $strErrorFileContents = ${storageSpool()->get($strErrorFile)};

        $self->testResult(
            $strErrorFileContents =~ ("42\nremote process on '" . BOGUS . "' terminated.*"), true, "check error file contents");

        # Disable async archiving
        $self->optionTestClear(CFGOPT_REPO_HOST);
        $self->optionTestClear(CFGOPT_PROTOCOL_TIMEOUT);
        $self->optionTestClear(CFGOPT_ARCHIVE_TIMEOUT);
        $self->optionTestClear(CFGOPT_ARCHIVE_ASYNC);
        $self->optionTestClear(CFGOPT_SPOOL_PATH);
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);
    }

    ################################################################################################################################
    if ($self->begin("ArchivePushFile::archivePushFile - encryption"))
    {
        my $iWalTimeline = 1;
        my $iWalMajor = 1;
        my $iWalMinor = 1;

        $self->optionTestSet(CFGOPT_REPO_CIPHER_TYPE, CFGOPTVAL_REPO_CIPHER_TYPE_AES_256_CBC);
        $self->optionTestSet(CFGOPT_REPO_CIPHER_PASS, 'x');
        $self->configTestLoad(CFGCMD_ARCHIVE_PUSH);

        # Remove any archive info files
        executeTest('sudo rm ' . $self->{strArchivePath} . '/archive.info*');

        # Clear the repo settings
        storageRepoCacheClear($self->stanza());

        my $oArchiveInfo = new pgBackRest::Archive::Info(storageRepo()->pathGet(STORAGE_REPO_ARCHIVE), false,
            {bLoad => false, bIgnoreMissing => true, strCipherPassSub => 'y'});
        $oArchiveInfo->create(PG_VERSION_94, $self->dbSysId(PG_VERSION_94), true);

        # Generate a normal segment
        my $strSegment = $self->walSegment($iWalTimeline, $iWalMajor, $iWalMinor++);
        $self->walGenerate($self->{strWalPath}, PG_VERSION_94, 1, $strSegment);

        $self->testResult(
            sub {archivePushFile($self->{strWalPath}, $strSegment, false, false)}, '[undef]',
            "${strSegment} WAL segment to pushed");

        $self->testResult(storageRepo()->encrypted($self->{strArchivePath} . "/" . $self->{strArchiveId} . "/" .
            substr($strSegment, 0, 16) . "/$strSegment-" . $self->{strWalHash}), true, '    pushed segment is encrypted');
    }
}

1;

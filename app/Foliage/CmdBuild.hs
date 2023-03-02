{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

module Foliage.CmdBuild (cmdBuild) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Tar
import Codec.Compression.GZip qualified as GZip
import Control.Monad (unless, void, when)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Traversable (for)
import Development.Shake
import Development.Shake.FilePath
import Distribution.Package
import Distribution.Parsec (simpleParsec)
import Distribution.Pretty (prettyShow)
import Foliage.HackageSecurity hiding (ToJSON, toJSON)
import Foliage.Meta
import Foliage.Meta.Aeson ()
import Foliage.Options
import Foliage.Pages
import Foliage.PrepareSdist
import Foliage.PrepareSource (addPrepareSourceRule, prepareSource)
import Foliage.RemoteAsset (addFetchRemoteAssetRule)
import Foliage.Shake
import Foliage.Time qualified as Time
import Hackage.Security.Util.Path (castRoot, toFilePath)
import Network.URI (URI (uriPath, uriQuery, uriScheme), nullURI)
import System.Directory (createDirectoryIfMissing)

cmdBuild :: BuildOptions -> IO ()
cmdBuild buildOptions = do
  outputDirRoot <- liftIO $ makeAbsolute (fromFilePath (buildOptsOutputDir buildOptions))
  shake opts $
    do
      addFetchRemoteAssetRule cacheDir
      addPrepareSourceRule (buildOptsInputDir buildOptions) cacheDir
      addPrepareSdistRule outputDirRoot
      phony "buildAction" (buildAction buildOptions)
      want ["buildAction"]
  where
    cacheDir = "_cache"
    opts =
      shakeOptions
        { shakeFiles = cacheDir,
          shakeVerbosity = Verbose,
          shakeThreads = buildOptsNumThreads buildOptions
        }

buildAction :: BuildOptions -> Action ()
buildAction
  BuildOptions
    { buildOptsSignOpts = signOpts,
      buildOptsCurrentTime = mCurrentTime,
      buildOptsExpireSignaturesOn = mExpireSignaturesOn,
      buildOptsInputDir = inputDir,
      buildOptsOutputDir = outputDir,
      buildOptsWriteMetadata = doWritePackageMeta
    } = do
    outputDirRoot <- liftIO $ makeAbsolute (fromFilePath outputDir)

    maybeReadKeysAt <- case signOpts of
      SignOptsSignWithKeys keysPath -> do
        ks <- doesDirectoryExist keysPath
        unless ks $ do
          putWarn $ "You don't seem to have created a set of TUF keys. I will create one in " <> keysPath
          liftIO $ createKeys keysPath
        return $ \name -> readKeysAt (keysPath </> name)
      SignOptsDon'tSign ->
        return $ const $ return []

    expiryTime <-
      for mExpireSignaturesOn $ \expireSignaturesOn -> do
        putInfo $ "Expiry time set to " <> Time.iso8601Show expireSignaturesOn
        return expireSignaturesOn

    currentTime <- case mCurrentTime of
      Nothing -> do
        t <- Time.truncateSeconds <$> liftIO Time.getCurrentTime
        putInfo $ "Current time set to " <> Time.iso8601Show t <> ". You can set a fixed time using the --current-time option."
        return t
      Just t -> do
        putInfo $ "Current time set to " <> Time.iso8601Show t <> "."
        return t

    packageVersions <- getPackageVersions inputDir

    makeIndexPage outputDir

    makeAllPackagesPage currentTime outputDir packageVersions

    makeAllPackageVersionsPage currentTime outputDir packageVersions

    when doWritePackageMeta $
      makeMetadataFile outputDir packageVersions

    void $ forP packageVersions $ makePackageVersionPage inputDir outputDir

    void $ forP packageVersions $ \pkgMeta@PackageVersionMeta {pkgId} -> do
      let PackageIdentifier {pkgName, pkgVersion} = pkgId
      cabalFilePath <- maybe (originalCabalFile pkgMeta) pure (revisedCabalFile inputDir pkgMeta)
      copyFileChanged cabalFilePath (outputDir </> "index" </> prettyShow pkgName </> prettyShow pkgVersion </> prettyShow pkgName <.> "cabal")

    cabalEntries <-
      foldMap
        ( \pkgMeta@PackageVersionMeta {pkgId, pkgSpec} -> do
            let PackageVersionSpec {packageVersionTimestamp, packageVersionRevisions} = pkgSpec

            -- original cabal file, with its timestamp (if specified)
            cabalFilePath <- originalCabalFile pkgMeta
            let cabalFileTimestamp = fromMaybe currentTime packageVersionTimestamp
            cf <- prepareIndexPkgCabal pkgId cabalFileTimestamp cabalFilePath

            -- all revised cabal files, with their timestamp
            revcf <-
              for packageVersionRevisions $
                \RevisionSpec {revisionTimestamp, revisionNumber} ->
                  prepareIndexPkgCabal
                    pkgId
                    revisionTimestamp
                    (cabalFileRevisionPath inputDir pkgId revisionNumber)

            return $ cf : revcf
        )
        packageVersions

    targetKeys <- maybeReadKeysAt "target"
    metadataEntries <-
      forP packageVersions $ \pkg@PackageVersionMeta {pkgId, pkgSpec} -> do
        let PackageIdentifier {pkgName, pkgVersion} = pkgId
        let PackageVersionSpec {packageVersionTimestamp} = pkgSpec
        targets <- prepareIndexPkgMetadata expiryTime pkg
        let path = outputDir </> "index" </> prettyShow pkgName </> prettyShow pkgVersion </> "package.json"
        liftIO $ BL.writeFile path $ renderSignedJSON targetKeys targets
        mkTarEntry
          (renderSignedJSON targetKeys targets)
          (IndexPkgMetadata pkgId)
          (fromMaybe currentTime packageVersionTimestamp)

    let tarContents = Tar.write $ sortOn Tar.entryTime (cabalEntries ++ metadataEntries)
    traced "Writing index" $ do
      BL.writeFile (anchorPath outputDirRoot repoLayoutIndexTar) tarContents
      BL.writeFile (anchorPath outputDirRoot repoLayoutIndexTarGz) $ GZip.compress tarContents

    privateKeysRoot <- maybeReadKeysAt "root"
    privateKeysTarget <- maybeReadKeysAt "target"
    privateKeysSnapshot <- maybeReadKeysAt "snapshot"
    privateKeysTimestamp <- maybeReadKeysAt "timestamp"
    privateKeysMirrors <- maybeReadKeysAt "mirrors"

    liftIO $
      writeSignedJSON outputDirRoot repoLayoutMirrors privateKeysMirrors $
        Mirrors
          { mirrorsVersion = FileVersion 1,
            mirrorsExpires = FileExpires expiryTime,
            mirrorsMirrors = []
          }

    liftIO $
      writeSignedJSON outputDirRoot repoLayoutRoot privateKeysRoot $
        Root
          { rootVersion = FileVersion 1,
            rootExpires = FileExpires expiryTime,
            rootKeys =
              fromKeys $
                concat
                  [ privateKeysRoot,
                    privateKeysTarget,
                    privateKeysSnapshot,
                    privateKeysTimestamp,
                    privateKeysMirrors
                  ],
            rootRoles =
              RootRoles
                { rootRolesRoot =
                    RoleSpec
                      { roleSpecKeys = map somePublicKey privateKeysRoot,
                        roleSpecThreshold = KeyThreshold 2
                      },
                  rootRolesSnapshot =
                    RoleSpec
                      { roleSpecKeys = map somePublicKey privateKeysSnapshot,
                        roleSpecThreshold = KeyThreshold 1
                      },
                  rootRolesTargets =
                    RoleSpec
                      { roleSpecKeys = map somePublicKey privateKeysTarget,
                        roleSpecThreshold = KeyThreshold 1
                      },
                  rootRolesTimestamp =
                    RoleSpec
                      { roleSpecKeys = map somePublicKey privateKeysTimestamp,
                        roleSpecThreshold = KeyThreshold 1
                      },
                  rootRolesMirrors =
                    RoleSpec
                      { roleSpecKeys = map somePublicKey privateKeysMirrors,
                        roleSpecThreshold = KeyThreshold 1
                      }
                }
          }

    rootInfo <- computeFileInfoSimple' (anchorPath outputDirRoot repoLayoutRoot)
    mirrorsInfo <- computeFileInfoSimple' (anchorPath outputDirRoot repoLayoutMirrors)
    tarInfo <- computeFileInfoSimple' (anchorPath outputDirRoot repoLayoutIndexTar)
    tarGzInfo <- computeFileInfoSimple' (anchorPath outputDirRoot repoLayoutIndexTarGz)

    liftIO $
      writeSignedJSON outputDirRoot repoLayoutSnapshot privateKeysSnapshot $
        Snapshot
          { snapshotVersion = FileVersion 1,
            snapshotExpires = FileExpires expiryTime,
            snapshotInfoRoot = rootInfo,
            snapshotInfoMirrors = mirrorsInfo,
            snapshotInfoTar = Just tarInfo,
            snapshotInfoTarGz = tarGzInfo
          }

    snapshotInfo <- computeFileInfoSimple' (anchorPath outputDirRoot repoLayoutSnapshot)
    liftIO $
      writeSignedJSON outputDirRoot repoLayoutTimestamp privateKeysTimestamp $
        Timestamp
          { timestampVersion = FileVersion 1,
            timestampExpires = FileExpires expiryTime,
            timestampInfoSnapshot = snapshotInfo
          }

makeMetadataFile :: FilePath -> [PackageVersionMeta] -> Action ()
makeMetadataFile outputDir packageVersions = traced "writing metadata" $ do
  createDirectoryIfMissing True (outputDir </> "foliage")
  Aeson.encodeFile
    (outputDir </> "foliage" </> "packages.json")
    (map encodePackageVersionMeta packageVersions)
  where
    encodePackageVersionMeta
      PackageVersionMeta
        { pkgId = PackageIdentifier {pkgName, pkgVersion},
          pkgSpec =
            PackageVersionSpec
              { packageVersionSource,
                packageVersionForce,
                packageVersionTimestamp
              }
        } =
        Aeson.object
          ( [ "pkg-name" Aeson..= pkgName,
              "pkg-version" Aeson..= pkgVersion,
              "url" Aeson..= sourceUrl packageVersionSource
            ]
              ++ ["forced-version" Aeson..= True | packageVersionForce]
              ++ (case packageVersionTimestamp of Nothing -> []; Just t -> ["timestamp" Aeson..= t])
          )

    sourceUrl :: PackageVersionSource -> URI
    sourceUrl (TarballSource uri Nothing) = uri
    sourceUrl (TarballSource uri (Just subdir)) = uri {uriQuery = "?dir=" ++ subdir}
    sourceUrl (GitHubSource repo rev Nothing) =
      nullURI
        { uriScheme = "github:",
          uriPath = T.unpack (unGitHubRepo repo) </> T.unpack (unGitHubRev rev)
        }
    sourceUrl (GitHubSource repo rev (Just subdir)) =
      nullURI
        { uriScheme = "github:",
          uriPath = T.unpack (unGitHubRepo repo) </> T.unpack (unGitHubRev rev),
          uriQuery = "?dir=" ++ subdir
        }

getPackageVersions :: FilePath -> Action [PackageVersionMeta]
getPackageVersions inputDir = do
  metaFiles <- getDirectoryFiles inputDir ["*/*/meta.toml"]

  when (null metaFiles) $ do
    putError $
      unlines
        [ "We could not find any package metadata file (i.e. _sources/<name>/<version>/meta.toml)",
          "Make sure you are passing the right input directory. The default input directory is _sources"
        ]
    fail "no package metadata found"

  forP metaFiles $ \metaFile -> do
    (pkgName, pkgVersion) <- case splitDirectories metaFile of
      [pkgName, pkgVersion, _] -> pure (pkgName, pkgVersion)
      _else -> fail $ "internal error: I should not be looking at " ++ metaFile
    name <- case simpleParsec pkgName of
      Nothing -> fail $ "invalid package name: " ++ pkgName
      Just name -> pure name
    version <- case simpleParsec pkgVersion of
      Nothing -> fail $ "invalid package version: " ++ pkgVersion
      Just version -> pure version
    let pkgId = PackageIdentifier name version

    pkgSpec <-
      readPackageVersionSpec' (inputDir </> metaFile) >>= \case
        PackageVersionSpec {packageVersionRevisions, packageVersionTimestamp = Nothing}
          | not (null packageVersionRevisions) -> do
              putError $
                unlines
                  [ inputDir </> metaFile <> " has cabal file revisions but the original package has no timestamp.",
                    "This combination doesn't make sense. Either add a timestamp on the original package or remove the revisions"
                  ]
              fail "invalid package metadata"
        PackageVersionSpec {packageVersionRevisions, packageVersionTimestamp = Just pkgTs}
          | any ((< pkgTs) . revisionTimestamp) packageVersionRevisions -> do
              putError $
                unlines
                  [ inputDir </> metaFile <> " has a revision with timestamp earlier than the package itself.",
                    "Adjust the timestamps so that all revisions come after the original package"
                  ]
              fail "invalid package metadata"
        meta ->
          return meta

    return $ PackageVersionMeta pkgId pkgSpec

prepareIndexPkgCabal :: PackageId -> UTCTime -> FilePath -> Action Tar.Entry
prepareIndexPkgCabal pkgId timestamp filePath = do
  need [filePath]
  contents <- liftIO $ BS.readFile filePath
  mkTarEntry (BL.fromStrict contents) (IndexPkgCabal pkgId) timestamp

prepareIndexPkgMetadata :: Maybe UTCTime -> PackageVersionMeta -> Action Targets
prepareIndexPkgMetadata expiryTime PackageVersionMeta {pkgId, pkgSpec} = do
  srcDir <- prepareSource pkgId pkgSpec
  sdist <- prepareSdist srcDir
  targetFileInfo <- computeFileInfoSimple' sdist
  let packagePath = repoLayoutPkgTarGz hackageRepoLayout pkgId
  return
    Targets
      { targetsVersion = FileVersion 1,
        targetsExpires = FileExpires expiryTime,
        targetsTargets = fromList [(TargetPathRepo packagePath, targetFileInfo)],
        targetsDelegations = Nothing
      }

mkTarEntry :: BL.ByteString -> IndexFile dec -> UTCTime -> Action Tar.Entry
mkTarEntry contents indexFile timestamp = do
  tarPath <- case Tar.toTarPath False indexPath of
    Left e -> fail $ "Invalid tar path " ++ indexPath ++ "(" ++ e ++ ")"
    Right tarPath -> pure tarPath

  pure
    (Tar.fileEntry tarPath contents)
      { Tar.entryTime = floor $ Time.utcTimeToPOSIXSeconds timestamp,
        Tar.entryOwnership =
          Tar.Ownership
            { Tar.ownerName = "foliage",
              Tar.groupName = "foliage",
              Tar.ownerId = 0,
              Tar.groupId = 0
            }
      }
  where
    indexPath = toFilePath $ castRoot $ indexFileToPath hackageIndexLayout indexFile

anchorPath :: Path Absolute -> (RepoLayout -> RepoPath) -> FilePath
anchorPath outputDirRoot p =
  toFilePath $ anchorRepoPathLocally outputDirRoot $ p hackageRepoLayout

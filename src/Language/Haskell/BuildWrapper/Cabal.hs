{-# LANGUAGE PatternGuards #-}
module Language.Haskell.BuildWrapper.Cabal where

import Language.Haskell.BuildWrapper.Base

import Control.Monad.State

import Data.Char
import Data.List
import Data.Maybe

import Distribution.ModuleName
import Distribution.PackageDescription (exposedModules, otherModules,library,executables,testSuites,Library,hsSourceDirs,libBuildInfo,Executable(..),exeName,modulePath,buildInfo,TestSuite(..),testName,TestSuiteInterface(..),testInterface,testBuildInfo,BuildInfo )
import Distribution.Simple.GHC
import Distribution.Simple.LocalBuildInfo                         
import qualified Distribution.Simple.Configure as DSC


import Text.Regex.TDFA

import System.Directory
import System.Exit
import System.FilePath
import System.Process

getFilesToCopy :: BuildWrapper(OpResult [FilePath])
getFilesToCopy =do
       (mfps,bwns)<-withCabal True getAllFiles
       return $ case mfps of
                Just fps->(concat $ map (\(_,_,_,ls)->map snd ls) fps,bwns)
                Nothing ->([],bwns); 


--maybe (return []) (\f->concat $ (map (\(_,_,ls)->ls)) f) getAllFiles

{--withCabal True (\gpd->do
                let pd=localPkgDescr  gpd
                let libs=maybe [] extractFromLib $ library pd
                let exes=concatMap extractFromExe $ executables pd
                let tests=concatMap extractFromTest $ testSuites pd
                return (libs ++ exes ++ tests)
        )
        where 
        extractFromLib :: Library -> [FilePath]
        extractFromLib l=let
                modules=(exposedModules l) ++ (otherModules $ libBuildInfo l)
                in copyModules modules (hsSourceDirs  $ libBuildInfo l)
        extractFromExe :: Executable -> [FilePath]
        extractFromExe e=let
                modules= (otherModules $ buildInfo e)
                hsd=hsSourceDirs  $ buildInfo e
                in (copyFiles [modulePath e] hsd)++ (copyModules modules hsd)     
        extractFromTest :: TestSuite -> [FilePath]
        extractFromTest e =let
                modules= (otherModules $ testBuildInfo e)
                hsd=hsSourceDirs  $ testBuildInfo e
                extras=case testInterface e of
                       (TestSuiteExeV10 _ mp)->(copyFiles [mp] hsd)
                       (TestSuiteLibV09 _ mn)->copyModules [mn] hsd
                       _->[]
                        in extras++ (copyModules modules hsd)
        copyModules :: [ModuleName] -> [FilePath] -> [FilePath]
        copyModules mods=copyFiles (concatMap (\m->[(toFilePath m) <.> "hs",(toFilePath m) <.> "lhs"]) mods)
        copyFiles :: [FilePath] -> [FilePath] -> [FilePath]
        copyFiles mods dirs=[d </> m  | m<-mods, d<-dirs]
        --}
    

cabalBuild :: BuildWrapper(OpResult Bool)
cabalBuild = do
        cf<-getCabalFile False
        cp<-gets cabalPath
        v<-gets cabalVerbosity
        dist_dir<-getDistDir
       
        let args=[
                "build",
                "--verbose="++(show $ fromEnum v),
                "--builddir="++dist_dir
                ]
        liftIO $ do
                cd<-getCurrentDirectory
                setCurrentDirectory (takeDirectory cf)
                (ex,_,err)<-readProcessWithExitCode cp args ""
                let ret=parseBuildMessages (takeFileName cf) err
                setCurrentDirectory cd
                return (ex==ExitSuccess,ret)

cabalConfigure :: Bool-> BuildWrapper (OpResult (Maybe LocalBuildInfo))
cabalConfigure srcOrTgt= do
        cf<-getCabalFile srcOrTgt
        cp<-gets cabalPath
        v<-gets cabalVerbosity
        dist_dir<-getDistDir
       
        let args=[
                "configure",
                "--verbose="++(show $ fromEnum v),
                "--user",
                "--enable-tests",
                "--builddir="++dist_dir
                ]
        {--(_,Just hOut,Just hErr)<-liftIO $ createProcess 
                ((proc cp args){
                        cwd = Just $takeDirectory cf,
                        std_out = CreatePipe,
                        std_err = CreatePipe
                        })--}
        liftIO $ do
                cd<-getCurrentDirectory
                setCurrentDirectory (takeDirectory cf)
        
                (ex,out,err)<-readProcessWithExitCode cp args ""
                --putStrLn err
                let msgs=(parseCabalMessages (takeFileName cf) err) -- ++ (parseCabalMessages (takeFileName cf) out)
                ret<-case ex of
                        ExitSuccess  -> do
                                lbi<-DSC.getPersistBuildConfig dist_dir
                                return (Just lbi,msgs)
                        ExitFailure _ -> return $ (Nothing,msgs)
                setCurrentDirectory cd
                return ret
        {-- 
        v<-gets cabalVerbosity
        gen_pkg_descr <- liftIO $ readPackageDescription v cf
        dist_dir<-getDistDir
        let prog_conf =defaultProgramConfiguration
        let user_flags = [] --getSessionSelector userFlags     
        let config_flags = 
                 (defaultConfigFlags prog_conf)
                   { configDistPref = Flag dist_dir
                   , configVerbosity = Flag v
                   , configUserInstall = Flag True
                , configTests = Flag True
              --  , configConfigurationsFlags = map (\(n,v)->(FlagName n,v)) user_flags
           }
        lbi<-liftIO $ handle (\(e :: IOError) ->  return $ Left $ BWNote BWError "Cannot configure:" (show e) (BWLocation cf 1 1)) $ do   
                lbi <- liftIO $ DSC.configure (gen_pkg_descr, (Nothing, []))
                           config_flags
                liftIO $ DSC.writePersistBuildConfig dist_dir lbi
                liftIO $ initialBuildSteps dist_dir (localPkgDescr lbi) lbi v
                            knownSuffixHandlers
                return $ Right lbi
        liftIO $ setCurrentDirectory cd
        return lbi --}
        -- cabal configure --buildir dist_dir -v=verbosity --user --enable-tests

getCabalFile :: Bool -> BuildWrapper FilePath
getCabalFile True= gets cabalFile
getCabalFile False= gets cabalFile
                         >>=return . takeFileName
                         >>=getTargetPath

cabalInit :: Bool -> BuildWrapper (OpResult (Maybe LocalBuildInfo))
cabalInit srcOrTgt= do
   cabal_file<-getCabalFile srcOrTgt
   dist_dir<-getDistDir
   let setup_config = DSC.localBuildInfoFile dist_dir
   conf'd <- liftIO $ doesFileExist setup_config
   if not conf'd 
        then cabalConfigure srcOrTgt
        else do
             cabal_time <- liftIO $ getModificationTime cabal_file
             conf_time <- liftIO $ getModificationTime setup_config
             if cabal_time >= conf_time 
                then cabalConfigure srcOrTgt
                else do
                        mb_lbi <- liftIO $ DSC.maybeGetPersistBuildConfig setup_config
                        case mb_lbi of
                          Nothing -> do
                            cabalConfigure srcOrTgt
                          Just _lbi -> do
                            return $ (Just _lbi,[])


withCabal :: Bool -> (LocalBuildInfo -> BuildWrapper (a))-> BuildWrapper (OpResult (Maybe a))  
withCabal srcOrTgt f=do
        (mlbi,notes)<-cabalInit srcOrTgt
        case mlbi of
                Nothing-> do
                        --liftIO $ putStrLn (show err)
                        return $ (Nothing,notes)
                Just lbi ->do
                        r<-(f lbi)
                        return (Just r, notes)
     

parseCabalMessages :: FilePath -> String -> [BWNote]
parseCabalMessages cf s=let
        (m,ls)=foldl parseCabalLine (Nothing,[]) $ lines s
        in nub $ case m of
                Nothing -> ls
                Just (bwn,msgs)->ls++[makeNote bwn msgs] 
        where 
                parseCabalLine :: (Maybe (BWNote,[String]),[BWNote]) -> String ->(Maybe (BWNote,[String]),[BWNote])
                parseCabalLine (currentNote,ls) l 
                        | isPrefixOf "Error:" l=(Nothing,ls++[BWNote BWError (dropWhile isSpace $ drop 6 l) "" (BWLocation cf 1 1)])
                        | isPrefixOf "Warning:" l=let
                                msg=(dropWhile isSpace $ drop 8 l)
                                msg2=if isPrefixOf cf msg
                                        then dropWhile isSpace $ drop ((length cf) + 1) msg
                                        else msg
                                in (Nothing,ls++[BWNote BWWarning msg2 "" (BWLocation cf (extractLine  msg2) 1)])
                        | isPrefixOf "cabal:" l=
                                let 
                                        s2=(dropWhile isSpace $ drop 6 l)
                                in if isPrefixOf "At least the following" s2
                                                then (Just $ (BWNote BWError "" "" (BWLocation cf 1 1),[s2]),ls)
                                                else 
                                                        let
                                                                (loc,rest)=span (/= ':') s2
                                                                (line,msg)=span (/= ':') (tail rest)
                                                        in (Nothing,ls++[BWNote BWError (dropWhile isSpace $ tail msg) "" (BWLocation loc (read line) 1)])
                        | Just (jcn,msgs)<-currentNote=
                                if (not $ null l)
                                        then (Just (jcn,l:msgs),ls)
                                        else (Nothing,ls++[makeNote jcn msgs])
                        | otherwise =(Nothing,ls)
                extractLine el=let
                        (_,_,_,ls)=el =~ "\\(line ([0-9]*)\\)" :: (String,String,String,[String])
                        in if null ls
                                then 0
                                else (read $ head ls)
 
parseBuildMessages :: FilePath -> String -> [BWNote]
parseBuildMessages cf s=let
        (m,ls)=foldl parseBuildLine (Nothing,[]) $ lines s
        in nub $ case m of
                Nothing -> ls
                Just (bwn,msgs)->ls++[makeNote bwn msgs] 
        where 
                parseBuildLine :: (Maybe (BWNote,[String]),[BWNote]) -> String ->(Maybe (BWNote,[String]),[BWNote])
                parseBuildLine (currentNote,ls) l  
                        | Just (jcn,msgs)<-currentNote=
                                if (not $ null l)
                                       then (Just (jcn,l:msgs),ls)
                                       else (Nothing,ls++[makeNote jcn msgs])
                        | Just n<-extractLocation l=(Just (n,[bwn_title n]),ls)
                        | otherwise =(Nothing,ls)
                extractLocation el=let
                        (_,_,aft,ls)=el =~ "([^:]+):([0-9]+):([0-9]+):" :: (String,String,String,[String])   
                        in case ls of
                                (loc:line:col:[])-> (Just $ BWNote BWError (dropWhile isSpace aft) "" (BWLocation loc (read line) (read col)))
                                _ -> Nothing

makeNote :: BWNote  -> [String] ->BWNote
makeNote bwn msgs=let
        title=dropWhile isSpace $ unlines $ reverse msgs
        in if isPrefixOf "Warning:" title
                then bwn{bwn_title=dropWhile isSpace $ drop 8 title,bwn_status=BWWarning}    
                else bwn{bwn_title=title}      
             
fileGhcOptions :: FilePath -> BuildWrapper(OpResult (Maybe (ModuleName,[String])))
fileGhcOptions fp=do
        withCabal False (\lbi->do
                fps<-getAllFiles lbi
                let ok=filter (\(_,_,_,ls)->not $ null ls ) $
                        map (\(n1,n2,n3,ls)->(n1,n2,n3,filter (\(_,b)->b==fp) ls) ) 
                                fps
                -- filter (\(_,_,_,ls)->elem fp ls ) fps
                return $ if null ok
                        then (fromString "",[])
                        else let
                                (bi,clbi,fp,ls)=head ok
                              in (fst $ head ls,(ghcOptions lbi bi clbi fp))

            -- libraries, executables, test suite: BuildInfo + all relevant modules
            -- find if modules included correspond to a component            
                        -- what about generated modules?
              
                -- libraryConfig :: Maybe ComponentLocalBuildInfo executableConfigs :: [(String, ComponentLocalBuildInfo)] testSuiteConfigs :: [(String, ComponentLocalBuildInfo)]
    
                        -- ghcOptions :: LocalBuildInfo -> BuildInfo -> ComponentLocalBuildInfo
           -- -> FilePath -> [String]
           -- ghcOptions lbi bi clbi odir
                )
       
       
getAllFiles :: LocalBuildInfo -> BuildWrapper([(BuildInfo,ComponentLocalBuildInfo,FilePath,[(ModuleName,FilePath)])])     
getAllFiles lbi= do
                let pd=localPkgDescr lbi
                let libs=maybe [] extractFromLib $ library pd
                let exes=map extractFromExe $ executables pd
                let tests=map extractFromTest $ testSuites pd
                return (libs ++ exes ++ tests)
        where 
        extractFromLib :: Library -> [(BuildInfo,ComponentLocalBuildInfo,FilePath,[(ModuleName,FilePath)])]
        extractFromLib l=let
                lib=libBuildInfo l
                modules=(exposedModules l) ++ (otherModules lib)
                in [(lib,fromJust $ libraryConfig lbi,buildDir lbi,copyModules modules (hsSourceDirs lib))]
        extractFromExe :: Executable -> (BuildInfo,ComponentLocalBuildInfo,FilePath,[(ModuleName,FilePath)])
        extractFromExe e@Executable{exeName=exeName'}=let
                ebi=buildInfo e
                targetDir = buildDir lbi </> exeName'
                exeDir    = targetDir </> (exeName' ++ "-tmp")
                modules= (otherModules ebi)
                hsd=hsSourceDirs ebi
                in (ebi,fromJust $ lookup exeName' $ executableConfigs lbi,exeDir, copyFiles [modulePath e] hsd++ (copyModules modules hsd)  ) 
        extractFromTest :: TestSuite -> (BuildInfo,ComponentLocalBuildInfo,FilePath,[(ModuleName,FilePath)])
        extractFromTest t@TestSuite {testName=testName'} =let
                tbi=testBuildInfo t
                modules= (otherModules tbi )
                hsd=hsSourceDirs tbi
                extras=case testInterface t of
                       (TestSuiteExeV10 _ mp)->(copyFiles [mp] hsd)
                       (TestSuiteLibV09 _ mn)->copyModules [mn] hsd
                       _->[]
                in (tbi,fromJust $ lookup testName' $ testSuiteConfigs lbi,buildDir lbi,extras++ (copyModules modules hsd))
        copyModules :: [ModuleName] -> [FilePath] -> [(ModuleName,FilePath)]
        copyModules mods=copyFiles (concatMap (\m->[(toFilePath m) <.> "hs",((toFilePath m) <.> "lhs")]) mods)
        copyFiles :: [FilePath] -> [FilePath] -> [(ModuleName,FilePath)]
        copyFiles mods dirs=[(fromString $ fileToModule m,d </> m)  | m<-mods, d<-dirs]
        
moduleToString :: ModuleName -> String
moduleToString = concat . intersperse ['.'] . components
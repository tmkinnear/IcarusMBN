#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --job-name=MBNTask
#SBATCH --mail-type=END
#SBATCH --mail-user=${USER}@kent.ac.uk
#SBATCH --output=./%j.out
#SBATCH --error=./%j.err
echo "Starting..."



##Variables section
debug=true #sets debug mode "true" or "false" without quotes, lowercase
sleepTime=2 #seconds between checks
CONDAENV=testmpi #name of environment in conda for MPI
totalWidth=32 #should match ntasks-per-node
coresPerTask=2 #number of cores for each sim
numTasks=$((totalWidth/coresPerTask)) #autocalculated
MBN="/home/${USER}/MBN/mbnexplorer" #location of MBN binary
listToRun="list_ToRun.txt"
listRunning="list_Running.txt"
listComplete="list_Complete.txt"
listFailed="list_Failed.txt"

if $debug ; then echo "Logging debug from `date`, setting up environment" > debug.txt; fi

##Initialisation Section
source /home/${USER}/.bashrc #to get conda
conda activate ${CONDAENV} #activate conda env providing MPI
export LD_LIBRARY_PATH=/home/${USER}/miniconda3/envs/${CONDAENV}/lib #MPI library path

$MBN -use-server-license 129.12.24.24 #reconnect to license server

#print all variable values to debug file if required
if $debug
then
	echo "Variables:" >> debug.txt
	echo "    USER=$USER" >> debug.txt
	echo "    CONDAENV=$CONDAENV" >> debug.txt
	echo "    MBN=$MBN" >> debug.txt
	echo "    sleepTime=$sleepTime" >> debug.txt
	echo "    totalWidth=$totalWidth" >> debug.txt
	echo "    coresPerTask=$coresPerTask" >> debug.txt
	echo "    numTasks=$numTasks" >> debug.txt
	echo "    LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> debug.txt
	echo "    listToRun=$listToRun" >> debug.txt
	echo "    listRunning=$listRunning" >> debug.txt
	echo "    listComplete=$listComplete" >> debug.txt
	echo "    listFailed=$listFailed" >> debug.txt
fi

#if either Running or ToRun files already present, get their number of lines
if [ -f ${listRunning} ]; then
	numRunning=`cat ${listRunning} | wc -l`
else
	numRunning=0
fi
if [ -f ${listToRun} ]; then
	numToRun=`cat ${listToRun} | wc -l`
else
	numToRun=0
fi

##Setup Section
if [ "${numRunning}" -gt 0 ] || [ "${numToRun}" -gt 0 ] ;
then
	#if either Running or ToRun already have task files, carry on from where things must have left off
	if $debug ; then echo "Restarting from prior state, adding any tasks from $listRunning back to $listToRun" >> debug.txt; fi
	cat $listRunning >> $listToRun
	echo -n "" > $listRunning
else
	#if Running and ToRun either do not exist or are empty, start from scratch
	if $debug ; then echo "No $listRunning file, creating list files and populating with task files" >> debug.txt; fi
	touch $listRunning
	touch $listComplete
	touch $listFailed
	ls -1 *.task > $listToRun
fi


##Subscheduler Section
while :
do
	if $debug ; then echo "++++New check cycle `date`++++" >> debug.txt; fi
	#determine quantity currently running and remaining to run
	numRunning=`cat ${listRunning} | wc -l`
	numToRun=`cat ${listToRun} | wc -l`
	if $debug ; then echo "There appear to be $numRunning tasks running, and $numToRun tasks to run." >> debug.txt; fi	
	if [ "$numRunning" -lt "$numTasks" ] && [ "$numToRun" -gt 0 ]; then
		#if we haven't capped out number we can run, and there are still more in the queue...
		if $debug ; then echo "We have not run out of tasks to run, and there is space to run one" >> debug.txt; fi

		newTask=`tail -n 1 $listToRun` #...pick task file from list...
		
		if $debug ; then echo "Task named $newTask at top of queue, attemping to run it" >> debug.txt; fi

		#...attempt to run task file, then pause a moment (1 second) for it to get started
		mpirun -np ${coresPerTask} $MBN -t $newTask > $newTask.stdout 2> $newTask.stderr &
		sleep 1
		if [ -z "`pgrep -f "$newTask"`" ] && [ ! -z "`grep "Have a nice day\!" ${newTask%.task}.out`" ] ; then
			#if the process doesn't exist, but the .out file shows completion, it must have run in < 1 second. Add it to completed list
			if $debug ; then echo "$newTask appeared to run and complete successfully within a second, adding to complete list and popping from toRun list" >> debug.txt; fi
			echo $newTask >> $listComplete
			head -n $((numToRun - 1)) $listToRun > list_Temp.txt
			mv list_Temp.txt $listToRun
		elif [ -z "`pgrep -f "$newTask"`" ] && [ -z "`cat $newTask.stderr`" ] ; then
			#if the process isn't running and there is no error (and implicitly it did not successfully complete) then pop it back into the queue to try again - this is almost certainly a license server issue
			if $debug ; then echo "$newTask failed without error - may be server restart, trying again shortly" >> debug.txt; fi
			rm $newTask.stderr $newTast.stdout
		elif [ -z "`pgrep -f "$newTask"`" ] ; then
			#if the process failed based on similar criteria to above and *did* make an error file...
			if $debug ; then echo "$newTask appeared to fail with errors, waiting a minute and trying once more" >> debug.txt; fi
			#...wait one minute, and then attempt one further run of the task file, this is to account for license server restarts for multithreaded tasks which *do* appear to produce error files.
			sleep 60
			mpirun -np ${coresPerTask} $MBN -t $newTask > $newTask.stdout 2> $newTask.stderr &
			sleep 1
			if [ -z "`pgrep -f "$newTask"`" ] && [ -z "`grep "Have a nice day\!" ${newTask%.task}.out`" ] ; then
				#if it fails again again for any reason (with/without errors), add it to failed list
				if $debug ; then echo "$newTask appeared to fail with errors, adding it to failed list and popping from toRun list" >> debug.txt; fi
				echo $newTask >> $listFailed
				head -n $((numToRun - 1)) $listToRun > list_Temp.txt
				mv list_Temp.txt $listToRun
			else
				#otherwise it is running successfully, add it to running list
				echo $newTask >> $listRunning
				head -n $((numToRun - 1)) $listToRun > list_Temp.txt
				mv list_Temp.txt $listToRun
			fi
		else
			#process must be running successfully, add it to running list and pop from torun list.
			if $debug ; then echo "$newTask appeared to start running successfully, adding to running list and popping from toRun list" >> debug.txt; fi
			echo $newTask >> $listRunning
			head -n $((numToRun - 1)) $listToRun > list_Temp.txt
			mv list_Temp.txt $listToRun
		fi
	elif [ "$numRunning" -eq 0 ] && [ "$numToRun" -eq 0 ]; then
		#if there are no tasks left to run, and nothing is running, everything is finished, end the loop
		if $debug ; then echo "We appear to be out of tasks to run, ending process!" >> debug.txt; fi
		break
	else
		#if there are a maximum of tasks currently running, nothing to do for the moment
		if $debug ; then echo "Max tasks ongoing, nothing to do" >> debug.txt; fi
	fi

	#checking the running list for how the tasks are doing
	if $debug ; then echo "About to commence task end checks" >> debug.txt; fi
	echo -n "" > list_Temp.txt #initialise a temporary list
	while read examineTask; do #check each task name from the Running list
		if $debug ; then echo "Checking task named $examineTask" >> debug.txt; fi
		if [ ! -z "$examineTask" ] ; then
			#if the task to examine is not empty (account for blank line errors)...
			pids="`pgrep -f "$examineTask" -d' '`" #grab any PID associated with the task name
			if [ ! -z "$pids" ]; then
				#if the list of PIDs is not empty (i.e. there *are* such processes), report to debug file if needed and add task to the temp list
				if $debug
				then
					echo "$examineTask seems to still be running, pid(s) $pids" >> debug.txt
					for pid in $pids; do
						VmRSS="`cat /proc/$pid/status | grep VmRSS`"
						echo "$pid $VmRSS" >> debug.txt
					done
				fi
				echo $examineTask >> list_Temp.txt
			else
				if [ ! -z "`grep "Have a nice day\!" ${examineTask%.task}.out`" ]
				then
					#if there are no longer any PIDs for this task, and the output file shows success, add it to completed list...
					if $debug ; then echo "$examineTask seems to have finished successfully, moving to complete list" >> debug.txt; fi
					echo $examineTask >> $listComplete
				else
					#...otherwise the task has ended without success, add it to the failed list
					if $debug ; then echo "$examineTask seems to have finished unsuccessfully, moving to failed list" >> debug.txt; fi
					echo $examineTask >> $listFailed
				fi
			fi
		else
			if $debug ; then echo "Task name line appears to be blank! Skipping!" >> debug.txt; fi
		fi
	done < $listRunning
	mv list_Temp.txt $listRunning #overwrite the extant list of running tasks with the temporary list of tasks still running at check

	#wait a set number of seconds for the next checking cycle
	sleep $sleepTime
done




echo "Done!"
